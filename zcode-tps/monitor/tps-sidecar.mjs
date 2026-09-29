// ZCode TPS · 数据 sidecar（DESIGN.md §7/§8/§9）
//
// PowerShell 5.1 没有 SQLite provider（DESIGN.md §3.3），而会话标题与流式字节只存在
// 于 db.sqlite。本进程用 node 内置的 node:sqlite（>= 22.5）只读轮询该库，把标题表与
// 活跃会话「当前 message 的分类型字节数」写成交换文件；监控进程只读文件，不碰 sqlite。
//
// 用法：node tps-sidecar.mjs <db.sqlite> <out.json> <parentPid> [intervalMs=250]
//
// 生命周期：
//   parentPid 消失即自杀——监控被强杀时不留孤儿进程；
//   db 打不开立即退出（exit 2），由监控按「快照陈旧 → 重启 → 连续 3 次失败
//   进入精简模式」接管（DESIGN.md §9）；
//   查询失败（如表结构变更）不退出，跳过该拍；连续 20 拍失败才退出交回监控。
//
// 查询代价（DESIGN.md §3.2 的约束）：轮询必须由已知 session_id 驱动——
// message 走 (session_id, time_created, id) 索引、part 走 (message_id, id) 索引，
// 绝不按时间扫 part 表（该列无索引，实测全表扫 241ms，按 4Hz 轮询等于吃满一核）。

import { DatabaseSync } from 'node:sqlite';
import { copyFileSync, mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { dirname } from 'node:path';

const [dbPath, outPath, parentPid, intervalArg] = process.argv.slice(2);
if (!dbPath || !outPath) { process.exit(2); }

const intervalMs = Math.min(2000, Math.max(200, Number(intervalArg) || 250));
// 不按 time_updated 过滤标题：恢复旧会话时 rollout 文件会新建，但库里的 time_updated
// 不跟着刷新（实测 3 天前的会话刚被切回），按时间窗口取会漏标题。表很小
// （实测 218 行），只留行数上限防异常膨胀。
const LIMIT = 500;                   // 单次快照的标题数上限
const TITLE_MAX = 60;                // DESIGN.md §8：标题截断到 60 字符
const MAX_QUERY_FAILS = 20;
// 活跃会话集合（DESIGN.md §7.2）：session.time_updated 在该窗口内的会话。
// 窗口取得比主进程的显示窗口（5 分钟）宽一档，过滤留给监控做，sidecar 只管备齐数据。
const ACTIVE_MS = 10 * 60 * 1000;
const ACTIVE_LIMIT = 8;              // 多行 UI 上限 5 行 + 折叠，这里再放宽一档

function parentAlive() {
  if (!parentPid) { return true; }
  try {
    process.kill(Number(parentPid), 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';  // 存在但无权限发信号，也算活着
  }
}

let db = null;
try {
  db = new DatabaseSync(dbPath, { readOnly: true });
} catch {
  process.exit(2);
}

const stmtTitles = db.prepare(
  'SELECT id, title, time_updated, task_type FROM session ORDER BY time_updated DESC LIMIT ?');

// 最新 message：走 (session_id, time_created, id) 索引取最新几条，role 在 data 的
// JSON 里，SQL 侧解析不划算，拿到 JS 里挑最新的 assistant。
const stmtMsgs = db.prepare(
  'SELECT id, sequence, data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 8');

// part 走 (message_id, id) 索引；只取字节长度，分类型合计在 JS 里做。
const stmtParts = db.prepare(
  'SELECT data FROM part WHERE message_id = ? ORDER BY sequence');

// part.data 都是 {"type":"..."} 开头（实测样本），用前缀正则分类，不整体 JSON.parse——
// part.data 是完整的文本/载荷，长生成下单条可达几十 KB，4Hz × 全 parts 解析不值。
// reasoning/text 是模型文本输出，参与速率换算；tool/step-start 等是载荷与标记，
// 不参与（DESIGN.md §12：k 按 part 类型分别标定，不含 tool）。
function pickType(data) {
  const m = /^\{"type":"([a-z-]+)"/.exec(data);
  return m ? m[1] : 'other';
}

function collectParts(messageId) {
  const bytes = { reasoning: 0, text: 0, other: 0 };
  let rows;
  try {
    rows = stmtParts.all(messageId);
  } catch {
    return null;                  // 表结构变更：本会话本拍无字节数
  }
  for (const r of rows) {
    const t = pickType(r.data);
    if (t === 'reasoning' || t === 'text') { bytes[t] += r.data.length; }
    else { bytes.other += r.data.length; }
  }
  return bytes;
}

let queryFails = 0;

function tick() {
  if (!parentAlive()) { process.exit(0); }
  let rows = null;
  try {
    rows = stmtTitles.all(LIMIT);
  } catch {
    queryFails++;
    if (queryFails >= MAX_QUERY_FAILS) { process.exit(3); }
    return;
  }
  queryFails = 0;

  const now = Date.now();
  const titles = {};
  const sessions = [];
  for (const r of rows) {
    if (!r.id) { continue; }
    // 按码点截断，避免 slice 切开代理对产出孤立代理项
    let title = '';
    if (r.title) {
      const chars = Array.from(String(r.title));
      title = chars.length > TITLE_MAX ? chars.slice(0, TITLE_MAX).join('') : chars.join('');
    }
    titles[r.id] = title;

    if (sessions.length >= ACTIVE_LIMIT) { continue; }
    if (r.task_type === 'subagent_child') { continue; }   // 子代理不进活跃列表（DESIGN.md §7.2）
    if (!r.time_updated || now - Number(r.time_updated) > ACTIVE_MS) { continue; }

    const sess = {
      id: r.id,
      title,
      lastActiveMs: Number(r.time_updated),
      msgId: '',
      msgSeq: null,
      parts: null,
    };
    // 最新 assistant message = 正在生成的那个（user 输入不落 message 表的 parts）
    try {
      const msgs = stmtMsgs.all(r.id);
      for (const m of msgs) {
        let role = '';
        try { role = JSON.parse(m.data).role || ''; } catch { }
        if (role === 'assistant') {
          sess.msgId = m.id;
          sess.msgSeq = m.sequence;
          sess.parts = collectParts(m.id);
          break;
        }
      }
    } catch { }
    sessions.push(sess);
  }

  // 原子覆盖：写临时文件再 copy 过去。不用 rename——目标被并发读取时
  // MoveFileEx 的覆盖语义与监控读到半截的窗口更长（DESIGN.md §8 沿用 v1 的坑）。
  const tmp = outPath + '.tmp';
  writeFileSync(tmp, JSON.stringify({ t: Date.now(), titles, sessions }), 'utf8');
  copyFileSync(tmp, outPath);
  unlinkSync(tmp);
}

mkdirSync(dirname(outPath), { recursive: true });
function loop() {
  try { tick(); } catch { }
  setTimeout(loop, intervalMs);
}
loop();
