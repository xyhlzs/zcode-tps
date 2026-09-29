// ZCode TPS · sidecar 数据契约测试（DESIGN.md §8）
//
// 用 node:sqlite 造一个临时合成库，起真实的 sidecar 子进程轮询它，
// 断言交换文件的内容与契约一致；再追加一个 part（模拟流式落库），
// 断言字节数跟着增长。不依赖真实 ZCode 数据。
//
// 用法：node tests\sidecar-test.mjs
// 退出码：0 = 全部通过，1 = 有失败。

import { DatabaseSync } from 'node:sqlite';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const sidecarPath = join(here, '..', 'monitor', 'tps-sidecar.mjs');

let pass = 0;
let fail = 0;
function check(name, ok, detail = '') {
  if (ok) { console.log('  PASS  ' + name); pass++; }
  else { console.log('  FAIL  ' + name + (detail ? '   <- ' + detail : '')); fail++; }
}

const dir = mkdtempSync(join(tmpdir(), 'zcode-tps-sidecar-'));
const dbPath = join(dir, 'db.sqlite');
const outPath = join(dir, 'sidecar.json');

// 列与真实库一致（只建 sidecar 用到的三张表与索引）
const db = new DatabaseSync(dbPath);
db.exec(`
  CREATE TABLE session (
    id text primary key, title text not null, time_updated integer not null,
    task_type text not null default 'interactive');
  CREATE INDEX session_task_type_idx ON session(task_type);
  CREATE TABLE message (
    id text primary key, session_id text not null, time_created integer not null,
    data text not null, sequence integer);
  CREATE INDEX message_session_time_created_id_idx ON message(session_id, time_created, id);
  CREATE TABLE part (
    id text primary key, message_id text not null, session_id text not null,
    data text not null, sequence integer);
  CREATE INDEX part_message_id_id_idx ON part(message_id, id);
`);

const now = Date.now();
const sA = 'sess_aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
const sB = 'sess_bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
const sSub = 'sess_subagent_agent_5555-5555-4555-555555555555';
const sOld = 'sess_oldest000-3333-4333-8333-000000000000';
const mA = 'msg_aaa';
const mB = 'msg_bbb';

db.prepare('INSERT INTO session (id, title, time_updated, task_type) VALUES (?, ?, ?, ?)')
  .run(sA, '合成会话A', now, 'interactive');
db.prepare('INSERT INTO session (id, title, time_updated, task_type) VALUES (?, ?, ?, ?)')
  .run(sB, '会话B', now - 60_000, 'interactive');
db.prepare('INSERT INTO session (id, title, time_updated, task_type) VALUES (?, ?, ?, ?)')
  .run(sSub, '子代理', now, 'subagent_child');
db.prepare('INSERT INTO session (id, title, time_updated, task_type) VALUES (?, ?, ?, ?)')
  .run(sOld, '20分钟前的会话', now - 20 * 60_000, 'interactive');

db.prepare('INSERT INTO message (id, session_id, time_created, data, sequence) VALUES (?, ?, ?, ?, ?)')
  .run(mA, sA, now, JSON.stringify({ role: 'assistant', time: { created: now } }), 7);
db.prepare('INSERT INTO message (id, session_id, time_created, data, sequence) VALUES (?, ?, ?, ?, ?)')
  .run(mB, sB, now - 60_000, JSON.stringify({ role: 'assistant', time: { created: now } }), 3);

const partA = {
  r: '{"type":"reasoning","text":"' + '思'.repeat(250) + '"}',   // 250 个三字节字 + 头尾
  x: '{"type":"text","text":"' + '回'.repeat(100) + '"}',
  t: '{"type":"tool","callID":"c1","tool":"Bash","input":{},"result":"ok"}',
};
db.prepare('INSERT INTO part (id, message_id, session_id, data, sequence) VALUES (?, ?, ?, ?, ?)')
  .run('p_a1', mA, sA, partA.r, 0);
db.prepare('INSERT INTO part (id, message_id, session_id, data, sequence) VALUES (?, ?, ?, ?, ?)')
  .run('p_a2', mA, sA, partA.x, 1);
db.prepare('INSERT INTO part (id, message_id, session_id, data, sequence) VALUES (?, ?, ?, ?, ?)')
  .run('p_a3', mA, sA, partA.t, 2);
db.prepare('INSERT INTO part (id, message_id, session_id, data, sequence) VALUES (?, ?, ?, ?, ?)')
  .run('p_b1', mB, sB, '{"type":"tool","callID":"c2","tool":"Read","input":{},"result":"x"}', 0);

const child = spawn(process.execPath, [sidecarPath, dbPath, outPath, String(process.pid), '150'],
  { stdio: 'ignore' });

function readSnap() {
  try { return JSON.parse(readFileSync(outPath, 'utf8')); } catch { return null; }
}
async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// 断言口径说明：sidecar 的 data.length 是 JS 字符串的 UTF-16 码元数
//（与 SQLite length(text) 的字符数同基准），不是 UTF-8 字节数。
// 换算系数 k 的标定与使用都在这个口径上，单位自洽。
try {
  await sleep(900);
  const snap = readSnap();
  check('交换文件已写出', snap !== null, outPath);
  if (snap) {
    check('titles 全量输出（含子代理与旧会话）',
      snap.titles && snap.titles[sA] === '合成会话A' && snap.titles[sSub] === '子代理' &&
      snap.titles[sOld] === '20分钟前的会话',
      JSON.stringify(snap.titles));

    const ids = (snap.sessions || []).map(s => s.id);
    check('活跃集合恰 2 个（排除子代理与 20 分钟前的会话）',
      ids.length === 2 && ids.includes(sA) && ids.includes(sB),
      JSON.stringify(ids));

    const a = (snap.sessions || []).find(s => s.id === sA);
    check('A 的当前 message 正确（msgId/msgSeq）',
      a && a.msgId === mA && a.msgSeq === 7,
      a ? ('msgId=' + a.msgId) : 'A 不在活跃集合');

    check('A 分类型计数正确（reasoning/text；tool 归 other）',
      a && a.parts && a.parts.reasoning === partA.r.length && a.parts.text === partA.x.length &&
      a.parts.other === partA.t.length,
      a ? JSON.stringify(a.parts) : 'A 不在活跃集合');

    const b = (snap.sessions || []).find(s => s.id === sB);
    check('B 只有 tool part：reasoning/text 为 0',
      b && b.parts && b.parts.reasoning === 0 && b.parts.text === 0,
      b ? JSON.stringify(b.parts) : 'B 不在活跃集合');

    // 模拟流式落库：同一 message 追加一个 reasoning part
    const partAdd = '{"type":"reasoning","text":"' + '续'.repeat(50) + '"}';
    db.prepare('INSERT INTO part (id, message_id, session_id, data, sequence) VALUES (?, ?, ?, ?, ?)')
      .run('p_a4', mA, sA, partAdd, 3);
    await sleep(700);
    const snap2 = readSnap();
    const a2 = snap2 && (snap2.sessions || []).find(s => s.id === sA);
    check('追加 part 后计数跟着增长（4Hz 轮询可见）',
      a2 && a2.parts && a2.parts.reasoning === partA.r.length + partAdd.length,
      a2 ? JSON.stringify(a2.parts) : '快照缺失');
  }
} finally {
  child.kill();
  await sleep(300);
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* 句柄晚释放时留给系统清理 */ }
}

console.log('');
console.log('结果：通过 ' + pass + '，失败 ' + fail);
process.exit(fail > 0 ? 1 : 0);
