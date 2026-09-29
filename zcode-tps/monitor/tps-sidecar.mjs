// ZCode TPS · 标题 sidecar（DESIGN.md §7.1/§8/§9 的最小实现）
//
// PowerShell 5.1 没有 SQLite provider（DESIGN.md §3.3），而会话标题只存在于
// db.sqlite 的 session 表里。本进程用 node 内置的 node:sqlite（>= 22.5）只读
// 轮询该表，把最近活跃会话的标题写成交换文件；监控进程只读文件，不碰 sqlite。
//
// 用法：node tps-sidecar.mjs <db.sqlite> <out.json> <parentPid> [intervalMs=250]
//
// 生命周期：
//   parentPid 消失即自杀——监控被强杀时不留孤儿进程；
//   db 打不开立即退出（exit 2），由监控按「快照陈旧 → 重启 → 连续 3 次失败
//   进入精简模式」接管（DESIGN.md §9）；
//   查询失败（如表结构变更）不退出，跳过该拍；连续 20 拍失败才退出交回监控。

import { DatabaseSync } from 'node:sqlite';
import { copyFileSync, mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { dirname } from 'node:path';

const [dbPath, outPath, parentPid, intervalArg] = process.argv.slice(2);
if (!dbPath || !outPath) { process.exit(2); }

const intervalMs = Math.min(2000, Math.max(200, Number(intervalArg) || 250));
// 不按 time_updated 过滤：恢复旧会话时 rollout 文件会新建，但库里的 time_updated
// 不跟着刷新（实测 3 天前的会话刚被切回），按时间窗口取会漏标题。表很小
// （实测 218 行），只留行数上限防异常膨胀。
const LIMIT = 500;                   // 单次快照的会话数上限
const TITLE_MAX = 60;                // DESIGN.md §8：标题截断到 60 字符
const MAX_QUERY_FAILS = 20;

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

const stmt = db.prepare(
  'SELECT id, title FROM session ORDER BY time_updated DESC LIMIT ?');

let queryFails = 0;

function tick() {
  if (!parentAlive()) { process.exit(0); }
  let rows = null;
  try {
    rows = stmt.all(LIMIT);
  } catch {
    queryFails++;
    if (queryFails >= MAX_QUERY_FAILS) { process.exit(3); }
    return;
  }
  queryFails = 0;
  const titles = {};
  for (const r of rows) {
    if (!r.id || !r.title) { continue; }
    // 按码点截断，避免 slice 切开代理对产出孤立代理项
    const chars = Array.from(String(r.title));
    titles[r.id] = chars.length > TITLE_MAX ? chars.slice(0, TITLE_MAX).join('') : chars.join('');
  }
  // 原子覆盖：写临时文件再 copy 过去。不用 rename——目标被并发读取时
  // MoveFileEx 的覆盖语义与监控读到半截的窗口更长（DESIGN.md §8 沿用 v1 的坑）。
  const tmp = outPath + '.tmp';
  writeFileSync(tmp, JSON.stringify({ t: Date.now(), titles }), 'utf8');
  copyFileSync(tmp, outPath);
  unlinkSync(tmp);
}

mkdirSync(dirname(outPath), { recursive: true });
function loop() {
  try { tick(); } catch { }
  setTimeout(loop, intervalMs);
}
loop();
