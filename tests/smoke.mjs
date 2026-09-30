#!/usr/bin/env node
// Smoke test for macOS and Linux. It starts fake Claude Code sessions (a
// process named like claude, with an MCP-like child and a dev-server-like
// child), registers them the way Claude Code does, and runs every command of
// sessions.mjs against them. It never touches real sessions: it uses its own
// temporary CLAUDE_CONFIG_DIR and only stops processes it started itself.
//
//   node tests/smoke.mjs
//
// Exit code 0 means every check passed. Paste the output into an issue either way.

import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform === 'win32') {
  console.log('This smoke test is for macOS and Linux; on Windows the plugin is tested against real sessions.');
  process.exit(0);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(root, 'skills', 'ramsleeper', 'scripts', 'sessions.mjs');
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ramsleeper-smoke-'));
// Children get only what they need, not the whole environment.
const env = { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR || os.tmpdir(), CLAUDE_CONFIG_DIR: home };
fs.mkdirSync(path.join(home, 'sessions'));
fs.mkdirSync(path.join(home, 'projects', 'smoke'), { recursive: true });

let failed = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`);
  if (!ok) failed++;
};
const run = (...args) => {
  try { return { code: 0, out: execFileSync(process.execPath, [script, ...args], { env, encoding: 'utf8' }) }; }
  catch (e) { return { code: e.status, out: `${e.stdout || ''}${e.stderr || ''}` }; }
};
const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const started = [];

// A fake session: exits cleanly on SIGINT, like Claude Code, and has two children.
function fakeSession() {
  const code = `
    const { spawn } = require('child_process');
    spawn(process.execPath, ['-e', 'setInterval(()=>{},1e6)', 'ramsleeper-smoke-mcp'], { stdio: 'ignore' });
    spawn(process.execPath, ['-e', 'setInterval(()=>{},1e6)', 'ramsleeper-smoke-vite'], { stdio: 'ignore' });
    process.on('SIGINT', () => process.exit(0));
    setInterval(() => {}, 1e6);`;
  const p = spawn(process.execPath, ['-e', code, 'claude-ramsleeper-smoke-session'], { stdio: 'ignore' });
  started.push(p.pid);
  return p;
}

function register(p, { status = 'idle', startedAt = Date.now() } = {}) {
  const sessionId = `5e55107e-0000-4000-8000-${String(p.pid).padStart(12, '0')}`;
  fs.writeFileSync(path.join(home, 'sessions', `${p.pid}.json`), JSON.stringify({
    pid: p.pid, sessionId, cwd: root, startedAt, status, entrypoint: 'cli', name: `smoke ${p.pid}`,
  }));
  fs.writeFileSync(path.join(home, 'projects', 'smoke', `${sessionId}.jsonl`),
    `${JSON.stringify({ type: 'user', message: { role: 'user', content: 'smoke test' } })}\n`);
  return sessionId;
}

try {
  console.log(`${os.type()} ${os.release()} ${os.arch()}, node ${process.version}\n`);

  const a = fakeSession();
  const b = fakeSession();
  const stale = fakeSession();
  await sleep(1500);
  const idA = register(a);
  const idB = register(b, { status: 'busy' });
  // A pid file whose start time does not match its process must be ignored.
  register(stale, { startedAt: Date.now() - 3 * 3600 * 1000 });

  let r = run('list', '--json');
  check('list --json runs', r.code === 0, r.code ? r.out.trim() : '');
  const data = r.code === 0 ? JSON.parse(r.out) : { sessions: [] };
  const sa = data.sessions.find(s => s.pid === a.pid);
  check('fake session is listed', Boolean(sa));
  check('stale pid file is ignored', !data.sessions.some(s => s.pid === stale.pid));
  check('children are found', sa?.children.length === 2, `found ${sa?.children.length}`);
  check('memory is measured', sa?.memBytes > 0, sa ? `${Math.round(sa.memBytes / 1048576)} MB` : '');
  check('dev server child is marked notable', sa?.children.some(c => c.notable && /vite/.test(c.cmd)));
  check('MCP child is not marked notable', sa?.children.some(c => !c.notable && /mcp/i.test(c.cmd)));

  r = run('list');
  check('list prints a table', r.code === 0 && r.out.includes(`smoke ${a.pid}`));

  r = run('xbar');
  check('xbar menu renders', r.code === 0 && r.out.split('\n')[0].includes('|'), r.out.split('\n')[0]);
  check('xbar offers unload and interrupt', r.out.includes('confirm-unload') && r.out.includes('--force'));

  r = run('unload', String(a.pid));
  check('preview runs', r.code === 0 && r.out.includes('Would unload'));
  r = run('unload', String(b.pid), `--expect=${idB}`, '--yes');
  check('busy session is refused without --force', r.code !== 0 && /busy/.test(r.out));
  r = run('unload', String(a.pid), '--expect=00000000-wrong', '--yes');
  check('wrong --expect is refused', r.code !== 0);
  r = run('unload', '3');
  check('row number is not taken as an ID prefix', r.code !== 0);

  r = run('unload', String(a.pid), `--expect=${idA}`, '--yes', '--json');
  const res = r.code === 0 ? JSON.parse(r.out) : {};
  check('unload succeeds', res.ok === true, r.code ? r.out.trim() : '');
  check('unload was graceful (SIGINT)', res.graceful === true);
  await sleep(500);
  check('session process is gone', !alive(a.pid));
  check('its children are gone', (sa?.children || []).every(c => !alive(c.pid)));
  check('its pid file is removed', !fs.existsSync(path.join(home, 'sessions', `${a.pid}.json`)));

  r = run('unload', String(b.pid), `--expect=${idB}`, '--yes', '--force', '--json');
  check('busy session unloads with --force', r.code === 0 && JSON.parse(r.out).ok === true);

  // Dashboard: start it, read the link, and call the API with and without the nonce.
  const srv = spawn(process.execPath, [script, 'serve', '--no-open'], { env, stdio: ['ignore', 'pipe', 'inherit'] });
  started.push(srv.pid);
  const link = await new Promise(resolve => {
    let buf = '';
    srv.stdout.on('data', d => { buf += d; const m = buf.match(/(http:\/\/127\.0\.0\.1:\d+\/\?t=\w+)/); if (m) resolve(m[1]); });
    setTimeout(() => resolve(null), 8000);
  });
  check('dashboard starts', Boolean(link));
  if (link) {
    const u = new URL(link);
    const nonce = u.searchParams.get('t');
    const page = await fetch(link);
    check('dashboard page loads with nonce', page.status === 200);
    const denied = await fetch(`${u.origin}/api/sessions`);
    check('API refuses requests without nonce', denied.status === 403);
    const api = await fetch(`${u.origin}/api/sessions`, { headers: { 'X-Ramsleeper-Nonce': nonce } });
    check('API answers with nonce', api.status === 200 && Array.isArray((await api.json()).sessions));
  }
  srv.kill();

  const bar = path.join(root, 'companion', 'menubar', 'ramsleeper.30s.sh');
  try {
    const out = execFileSync('bash', [bar], { env, encoding: 'utf8' });
    check('menu bar script runs', out.includes('|'), out.split('\n')[0]);
  } catch (e) { check('menu bar script runs', false, String(e.message).split('\n')[0]); }
} finally {
  for (const pid of started) { try { process.kill(pid, 'SIGKILL'); } catch { /* gone */ } }
  // Every fake process carries this marker in its command line.
  try { execFileSync('pkill', ['-f', 'ramsleeper-smoke-'], { stdio: 'ignore' }); } catch { /* none left */ }
  fs.rmSync(home, { recursive: true, force: true });
}

console.log(`\n${failed ? `${failed} check(s) failed` : 'All checks passed'}.`);
process.exit(failed ? 1 : 0);
