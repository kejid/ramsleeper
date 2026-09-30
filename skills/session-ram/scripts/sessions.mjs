#!/usr/bin/env node
// session-ram: list running Claude Code sessions with their memory use, and
// unload (stop) an idle session so it can be resumed later from its transcript.
//
// Data sources (all local, nothing is sent anywhere):
//   ~/.claude/sessions/<pid>.json          written by every running Claude Code process
//   ~/.claude/projects/*/<sessionId>.jsonl conversation transcript (what --resume reads)
//   <Claude app data>/claude-code-sessions desktop app metadata (session titles)
//   OS process table                       memory and process tree
//
// Usage:
//   node sessions.mjs list [--json]
//   node sessions.mjs unload <pid|session-id-prefix> [--expect=<session-id>] [--yes] [--force] [--json]
//   node sessions.mjs widget [--lang=en|ru]           HTML snapshot for inline chat widgets
//   node sessions.mjs xbar                            menu for xbar/SwiftBar (macOS), Argos/Kargos (Linux)
//   node sessions.mjs confirm-unload <pid>            native confirm dialog, then unload
//   node sessions.mjs serve [--port=N] [--no-open] [--tab] [--keep] [--setup]   local dashboard on 127.0.0.1

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
const PID_DIR = path.join(CLAUDE_DIR, 'sessions');
const PROJECTS_DIR = path.join(CLAUDE_DIR, 'projects');
const IS_WIN = process.platform === 'win32';

function desktopSessionsDir() {
  if (IS_WIN) return path.join(process.env.APPDATA || path.join(HOME, 'AppData', 'Roaming'), 'Claude', 'claude-code-sessions');
  if (process.platform === 'darwin') return path.join(HOME, 'Library', 'Application Support', 'Claude', 'claude-code-sessions');
  return path.join(process.env.XDG_CONFIG_HOME || path.join(HOME, '.config'), 'Claude', 'claude-code-sessions');
}

// ---------------------------------------------------------------- processes

// Returns Map<pid, {pid, ppid, name, cmd, mem (bytes), start (string|null)}>.
// On Windows `mem` is the private working set (the "Memory" column of Task
// Manager) and `start` is the creation time as a FILETIME string, the same
// format Claude Code writes to procStart. On macOS/Linux `mem` is RSS.
function readProcesses() {
  const procs = new Map();
  if (IS_WIN) {
    const script = `
      $ProgressPreference = 'SilentlyContinue'
      [Console]::OutputEncoding = [Text.Encoding]::UTF8
      $ws = @{}
      try { Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop | ForEach-Object { $ws[[string]$_.IDProcess] = [int64]$_.WorkingSetPrivate } } catch {}
      Get-CimInstance Win32_Process | ForEach-Object {
        $c = $_.CommandLine; if ($c -and $c.Length -gt 400) { $c = $c.Substring(0, 400) }
        $m = $ws[[string]$_.ProcessId]; if ($null -eq $m) { $m = [int64]$_.WorkingSetSize }
        [pscustomobject]@{ p = $_.ProcessId; pp = $_.ParentProcessId; n = $_.Name; c = $c; m = $m;
          s = $(if ($_.CreationDate) { $_.CreationDate.ToFileTimeUtc().ToString() } else { $null }) }
      } | ConvertTo-Json -Compress`;
    const out = execFileSync('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
      { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, windowsHide: true });
    for (const r of JSON.parse(out)) {
      procs.set(r.p, { pid: r.p, ppid: r.pp, name: r.n || '', cmd: r.c || '', mem: Number(r.m) || 0, start: r.s });
    }
  } else {
    // lstart is a fixed five-field date ("Wed Sep 30 13:22:01 2026") in the C locale.
    const out = execFileSync('ps', ['-axo', 'pid=,ppid=,rss=,lstart=,args='],
      { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, env: { ...process.env, LC_ALL: 'C' } });
    for (const line of out.split('\n')) {
      const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]{8}\s+\d{4})\s+(.*)$/);
      if (!m) continue;
      const cmd = m[5].slice(0, 400);
      const startMs = Date.parse(m[4].replace(/\s+/g, ' '));
      procs.set(+m[1], { pid: +m[1], ppid: +m[2], name: path.basename(cmd.split(' ')[0]), cmd, mem: +m[3] * 1024,
        start: null, startMs: Number.isNaN(startMs) ? null : startMs });
    }
  }
  return procs;
}

function childrenIndex(procs) {
  const idx = new Map();
  for (const p of procs.values()) {
    if (!idx.has(p.ppid)) idx.set(p.ppid, []);
    idx.get(p.ppid).push(p);
  }
  return idx;
}

// Windows reuses PIDs and never re-parents orphans, so a process whose parent
// died can look like a child of an unrelated newer process. A real child is
// never older than its parent.
function isRealChild(parent, child) {
  if (!IS_WIN || !parent.start || !child.start) return true;
  return BigInt(child.start) >= BigInt(parent.start);
}

function descendants(root, idx) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const p = stack.pop();
    for (const c of idx.get(p.pid) || []) {
      if (c.pid === p.pid || !isRealChild(p, c)) continue;
      out.push(c);
      stack.push(c);
    }
  }
  return out;
}

function ancestors(pid, procs) {
  const chain = [];
  const seen = new Set();
  let p = procs.get(pid);
  while (p && !seen.has(p.pid)) {
    seen.add(p.pid);
    chain.push(p.pid);
    p = procs.get(p.ppid);
  }
  return chain;
}

// Start time in the pid file vs the live process: guards against a stale pid
// file (left by a crash or by our own unload) whose PID now belongs to another
// program, including other claude-named processes such as the desktop app's
// helpers. Without a start time to compare, the file is not trusted.
function sameProcess(info, proc) {
  if (!proc) return false;
  if (!/claude/i.test(proc.name) && !/claude/i.test(proc.cmd)) return false;
  if (IS_WIN) {
    if (!info.procStart || !proc.start) return false;
    try {
      // FILETIME strings may lose a few digits of precision: allow one second.
      const diff = BigInt(info.procStart) - BigInt(proc.start);
      return (diff < 0n ? -diff : diff) < 10_000_000n;
    } catch { return false; }
  }
  if (!info.startedAt || !proc.startMs) return false;
  // ps reports whole seconds, and Claude Code writes startedAt shortly after it starts.
  const lag = info.startedAt - proc.startMs;
  return lag > -2000 && lag < 120000;
}

// ---------------------------------------------------------------- metadata

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function loadDesktopMeta() {
  const meta = new Map();
  const root = desktopSessionsDir();
  let lvl1 = [];
  try { lvl1 = fs.readdirSync(root); } catch { return meta; }
  for (const a of lvl1) {
    let lvl2 = [];
    try { lvl2 = fs.readdirSync(path.join(root, a)); } catch { continue; }
    for (const b of lvl2) {
      let files = [];
      try { files = fs.readdirSync(path.join(root, a, b)); } catch { continue; }
      for (const f of files) {
        if (!/^local_.*\.json$/.test(f)) continue;
        const j = readJson(path.join(root, a, b, f));
        if (j && j.sessionId) meta.set(j.sessionId, j);
      }
    }
  }
  return meta;
}

function findTranscript(sessionId) {
  let dirs = [];
  try { dirs = fs.readdirSync(PROJECTS_DIR); } catch { return null; }
  for (const d of dirs) {
    const f = path.join(PROJECTS_DIR, d, `${sessionId}.jsonl`);
    try {
      const st = fs.statSync(f);
      return { file: f, size: st.size, mtime: st.mtimeMs };
    } catch { /* next */ }
  }
  return null;
}

// First real user prompt, used as a title for sessions that have no name.
function firstPrompt(file) {
  let text = '';
  try {
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(256 * 1024);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    text = buf.subarray(0, n).toString('utf8');
  } catch { return null; }
  for (const line of text.split('\n')) {
    const j = (() => { try { return JSON.parse(line); } catch { return null; } })();
    if (!j || j.type !== 'user' || j.isMeta) continue;
    let c = j.message && j.message.content;
    if (Array.isArray(c)) c = c.filter(x => x.type === 'text').map(x => x.text).join(' ');
    if (typeof c !== 'string') continue;
    c = c.replace(/<[^>]+>[^<]*<\/[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    if (c) return c.slice(0, 80);
  }
  return null;
}

// ---------------------------------------------------------------- sessions

function collect() {
  const procs = readProcesses();
  const idx = childrenIndex(procs);
  const desktop = loadDesktopMeta();
  const myChain = new Set(ancestors(process.pid, procs));

  let files = [];
  try { files = fs.readdirSync(PID_DIR).filter(f => /^\d+\.json$/.test(f)); } catch { /* none */ }

  const sessions = [];
  for (const f of files) {
    const info = readJson(path.join(PID_DIR, f));
    if (!info || !info.pid) continue;
    const proc = procs.get(info.pid);
    if (!sameProcess(info, proc)) continue; // stale pid file

    const kids = descendants(proc, idx);
    const host = info.hostSessionId ? desktop.get(info.hostSessionId) : null;
    const transcript = info.sessionId ? findTranscript(info.sessionId) : null;
    const title = (host && host.title) || info.name ||
      (transcript && firstPrompt(transcript.file)) || path.basename(info.cwd || '') || '(untitled)';

    sessions.push({
      pid: info.pid,
      sessionId: info.sessionId || null,
      hostSessionId: info.hostSessionId || null,
      title,
      cwd: info.cwd || (host && host.cwd) || null,
      entrypoint: info.entrypoint || null,
      status: info.status || 'unknown',
      startedAt: info.startedAt || null,
      lastActivityAt: transcript ? Math.round(transcript.mtime) : (host && host.lastActivityAt) || null,
      transcript: transcript ? transcript.file : null,
      memBytes: proc.mem + kids.reduce((s, k) => s + k.mem, 0),
      ownMemBytes: proc.mem,
      processCount: 1 + kids.length,
      children: kids.map(k => ({ pid: k.pid, name: k.name, memBytes: k.mem, cmd: shortCmd(k.cmd), notable: isNotable(k) })),
      current: myChain.has(info.pid),
    });
  }
  sessions.sort((a, b) => b.memBytes - a.memBytes);
  sessions.forEach((s, i) => { s.n = i + 1; });

  // The desktop app itself (main Electron process + helpers), for context only.
  let app = null;
  const hostPids = new Set(sessions.map(s => procs.get(s.pid)?.ppid).filter(Boolean));
  for (const hp of hostPids) {
    const h = procs.get(hp);
    if (!h || !/^claude(\.exe)?$/i.test(h.name) || /claude-code/i.test(h.cmd)) continue;
    const sessionPids = new Set(sessions.map(s => s.pid));
    const helpers = (idx.get(h.pid) || []).filter(c => !sessionPids.has(c.pid) && /claude/i.test(c.name));
    app = { pid: h.pid, memBytes: h.mem + helpers.reduce((s, c) => s + c.mem, 0), processCount: 1 + helpers.length };
  }
  return { sessions, app, platform: process.platform, systemMemBytes: os.totalmem(), memMetric: IS_WIN ? 'private working set' : 'RSS' };
}

// A child process the user might not expect to lose, so confirmations call it
// out: dev servers, databases, browsers, anything unfamiliar. MCP servers and
// the shells and launchers that host them are routine and stay unmarked.
const MCP_RE = /mcp|modelcontextprotocol/i;
const DEV_RE = /\b(vite|next|nuxt|astro|remix|webpack|parcel|esbuild|nodemon|tsx|ts-node|jest|vitest|postgres|mysqld|mongod|redis-server|docker|uvicorn|gunicorn|flask|django|rails|php|java)\b/i;
const PLUMBING_RE = /^(conhost|cmd|powershell|pwsh|bash|sh|zsh|fish|uv|uvx|npx|npm|pnpm|yarn|node|bun|deno|git|python\d?(\.\d+)?)(\.exe)?$/i;
function isNotable(p) {
  if (DEV_RE.test(p.cmd)) return true;
  return !MCP_RE.test(p.cmd) && !PLUMBING_RE.test(p.name);
}

function shortCmd(cmd) {
  if (!cmd) return '';
  // Prefer a recognisable package or tool name (MCP servers, dev servers).
  const m = cmd.match(/(@[\w.-]+\/[\w.-]+|[\w.-]*mcp[\w.-]*|\b(?:vite|next|webpack|nodemon|tsx|playwright|chrome|msedge)\b)/i);
  if (m) return m[1].replace(/\.(exe|js|cjs|mjs)$/i, '');
  const args = cmd.replace(/^"[^"]+"|^\S+/, '').trim();
  return args.slice(0, 60);
}

// ---------------------------------------------------------------- output

const mb = b => `${Math.round(b / 1048576)} MB`;
function ago(ms) {
  if (!ms) return '-';
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 90) return 'just now';
  if (s < 5400) return `${Math.round(s / 60)} min ago`;
  if (s < 129600) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}
function pad(s, n) { s = String(s); return s.length > n ? s.slice(0, n - 1) + '…' : s.padEnd(n); }

function printList(data) {
  const { sessions, app } = data;
  if (!sessions.length) { console.log('No running Claude Code sessions found.'); return; }
  console.log(`${pad('#', 3)}${pad('Session', 44)}${pad('RAM', 9)}${pad('Procs', 6)}${pad('Status', 8)}${pad('Last activity', 15)}${pad('PID', 7)}ID`);
  for (const s of sessions) {
    const mark = s.current ? ' ◀ this session' : '';
    console.log(`${pad(s.n, 3)}${pad(s.title, 44)}${pad(mb(s.memBytes), 9)}${pad(s.processCount, 6)}${pad(s.status, 8)}${pad(ago(s.lastActivityAt), 15)}${pad(s.pid, 7)}${(s.sessionId || '').slice(0, 8)}${mark}`);
  }
  const total = sessions.reduce((t, s) => t + s.memBytes, 0);
  console.log(`\nTotal: ${mb(total)} in ${sessions.reduce((t, s) => t + s.processCount, 0)} processes across ${sessions.length} sessions (${data.memMetric}).`);
  if (app) console.log(`Claude desktop app itself: ${mb(app.memBytes)} in ${app.processCount} processes (never touched).`);
}

// ---------------------------------------------------------------- unload

// A number is only ever a PID, never a row number or an ID prefix, and an ID
// prefix must be long enough that it cannot match by accident.
const MIN_PREFIX = 6;
function resolve(sessions, target) {
  if (/^\d+$/.test(target)) return sessions.find(s => s.pid === Number(target)) || null;
  const t = target.toLowerCase().replace(/^local_/, '');
  if (t.length < MIN_PREFIX) throw new Error(`"${target}" is too short; give the PID or at least ${MIN_PREFIX} characters of the session ID.`);
  const hits = sessions.filter(s =>
    (s.sessionId && s.sessionId.startsWith(t)) ||
    (s.hostSessionId && s.hostSessionId.replace(/^local_/, '').startsWith(t)));
  if (hits.length > 1) throw new Error(`"${target}" matches ${hits.length} sessions; use more characters or the PID.`);
  return hits[0] || null;
}

function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// Stops exactly the processes shown in the plan: the session first, so it
// cannot start replacements, then its children. taskkill /T is not used
// because it follows parent PIDs blindly and would also reach unrelated
// orphans whose dead parent's PID was reused inside this tree.
function killTree(s) {
  if (IS_WIN) {
    const pids = [s.pid, ...s.children.map(c => c.pid)];
    // taskkill accepts many /PID arguments; stay well under the command-line limit.
    for (let i = 0; i < pids.length; i += 50) {
      const batch = pids.slice(i, i + 50).flatMap(p => ['/PID', String(p)]);
      try {
        execFileSync('taskkill.exe', ['/F', ...batch], { encoding: 'utf8', windowsHide: true, stdio: 'pipe' });
      } catch { /* some may already be gone; verified below */ }
    }
  } else {
    const all = [s.pid, ...s.children.map(c => c.pid)];
    for (const pid of all) { try { process.kill(pid, 'SIGTERM'); } catch { /* gone */ } }
    for (let i = 0; i < 30 && all.some(alive); i++) sleep(100);
    for (const pid of all) { if (alive(pid)) { try { process.kill(pid, 'SIGKILL'); } catch { /* gone */ } } }
  }
  for (let i = 0; i < 30 && alive(s.pid); i++) sleep(100);
}

// Checks a session and, with `yes`, stops it. Returns a result object; never
// exits, so the dashboard server can use it too. `expectSessionId` guards the
// dashboard against a PID that changed hands between page refresh and click.
function unloadSession(target, { yes = false, force = false, expectSessionId = null } = {}) {
  const { sessions } = collect();
  const s = resolve(sessions, target);
  const refuse = error => ({ ok: false, error });
  if (!s) return refuse(`no running Claude Code session matches "${target}". Run "list" first.`);
  if (expectSessionId && s.sessionId !== expectSessionId) return refuse('the session list changed; refresh and try again.');
  if (s.current) return refuse('this is the session you are talking to right now; it cannot unload itself.');
  if (!s.transcript) return refuse('no transcript found for this session, so it could not be resumed after unloading.');
  // The preview always works, so a busy session can be shown with its warning.
  if (yes && s.status === 'busy' && !force) return refuse('the session is busy (a turn is running). Wait until it is idle, or pass --force.');

  const plan = planFor(s);
  if (!yes) return { ok: true, dryRun: true, plan, session: s };

  killTree(s);
  const survivors = [s.pid, ...s.children.map(c => c.pid)].filter(alive);
  const ok = !alive(s.pid);
  // A killed process cannot remove its own pid file; a stale one could later
  // match a reused PID, so drop it (only if it still describes this session).
  if (ok) {
    const f = path.join(PID_DIR, `${s.pid}.json`);
    if (readJson(f)?.sessionId === s.sessionId) { try { fs.unlinkSync(f); } catch { /* already gone */ } }
  }
  return {
    ok, unloaded: ok, freedBytes: ok ? s.memBytes : 0, survivors, plan, session: s,
    ...(ok ? {} : { error: `could not stop PID ${s.pid}.` }),
  };
}

function planFor(s) {
  return {
    n: s.n, pid: s.pid, title: s.title, sessionId: s.sessionId, hostSessionId: s.hostSessionId,
    cwd: s.cwd, status: s.status, entrypoint: s.entrypoint, memBytes: s.memBytes, processCount: s.processCount,
    children: s.children, transcript: s.transcript,
    resume: s.entrypoint === 'claude-desktop'
      ? 'Open the session in the Claude app sidebar and send a message; the app restarts it from the transcript.'
      : `cd "${s.cwd}" && claude --resume ${s.sessionId}`,
  };
}

function unloadCli(target, { yes, force, json, expectSessionId }) {
  const r = unloadSession(target, { yes, force, expectSessionId });
  const { session: s, plan } = r;
  delete r.session;
  if (json) { console.log(JSON.stringify(r, null, 2)); process.exit(r.ok ? 0 : 2); }
  if (!r.ok && !plan) { console.error(`Refused: ${r.error}`); process.exit(2); }

  if (r.dryRun) {
    console.log(`Would unload #${s.n} "${s.title}" (PID ${s.pid}, ${s.status})`);
    console.log(`  frees about ${mb(s.memBytes)} across ${s.processCount} processes:`);
    console.log(`    ${s.pid}  claude  ${mb(s.ownMemBytes)}`);
    for (const c of s.children) console.log(`  ${c.notable ? '! ' : '  '}${c.pid}  ${pad(c.name, 12)} ${pad(mb(c.memBytes), 8)} ${c.cmd}`);
    if (s.children.some(c => c.notable)) console.log('  ! = not an MCP server or shell; it stops too');
    console.log(`  transcript kept: ${s.transcript}`);
    console.log(`  to continue later: ${plan.resume}`);
    if (s.status === 'busy') console.log('  BUSY: a turn is running and will be cut off; the conversation up to it is kept.');
    console.log(`\nTo unload: unload ${s.pid} --expect=${s.sessionId} --yes${s.status === 'busy' ? ' --force' : ''}`);
    return;
  }
  if (r.ok) {
    console.log(`Unloaded #${s.n} "${s.title}": ~${mb(s.memBytes)} freed, ${s.processCount - r.survivors.length}/${s.processCount} processes stopped.`);
    if (r.survivors.length) console.log(`  still running: ${r.survivors.join(', ')}`);
    console.log(`  to continue: ${plan.resume}`);
    return;
  }
  console.error(`Could not stop PID ${s.pid}.`);
  process.exit(1);
}

// ---------------------------------------------------------------- chat widget

// An HTML fragment for chat surfaces that render inline widgets (the Claude
// desktop app's show_widget). It is a snapshot: buttons send a chat message
// through the host's sendPrompt(), and Claude then runs the normal preview and
// confirmation. Styling uses the host's CSS variables so it matches light/dark.
const WIDGET_TEXT = {
  en: { inSessions: 'In sessions', counts: 'Sessions / processes', app: 'Claude app itself', asOf: 'As of',
    refresh: 'Refresh', unload: 'Unload', idle: 'idle', busy: 'busy', current: 'this session', proc: 'proc.',
    mb: 'MB', gb: 'GB', none: 'No running Claude Code sessions.',
    interrupt: 'Interrupt', askRefresh: 'Refresh the session-ram list',
    askUnload: (t, pid, busy) => `Unload the session "${t}" (PID ${pid}) with session-ram${busy ? '; it is busy, so interrupt its running turn' : ''}` },
  ru: { inSessions: 'В сессиях', counts: 'Сессий / процессов', app: 'Само приложение', asOf: 'На',
    refresh: 'Обновить', unload: 'Выгрузить', idle: 'ждёт', busy: 'работает', current: 'эта сессия', proc: 'проц.',
    mb: 'МБ', gb: 'ГБ', none: 'Запущенных сессий Claude Code нет.',
    interrupt: 'Прервать', askRefresh: 'Обнови список сессий session-ram',
    askUnload: (t, pid, busy) => `Выгрузи сессию «${t}» (PID ${pid}) через session-ram${busy ? '; она работает — прерви текущий ход' : ''}` },
};

function widgetHtml(data, lang) {
  const L = WIDGET_TEXT[lang] || WIDGET_TEXT.en;
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const size = b => b >= 1073741824 ? `${(b / 1073741824).toFixed(1)} ${L.gb}` : `${Math.round(b / 1048576)} ${L.mb}`;
  const { sessions, app } = data;
  const total = sessions.reduce((t, s) => t + s.memBytes, 0);
  const procs = sessions.reduce((t, s) => t + s.processCount, 0);
  const max = Math.max(1, ...sessions.map(s => s.memBytes));
  const time = new Date().toLocaleTimeString(lang === 'ru' ? 'ru-RU' : 'en-US', { hour: '2-digit', minute: '2-digit' });
  const stat = (label, value) => `<div style="background:var(--surface-1);border-radius:var(--radius);padding:1rem"><div class="m">${label}</div><div style="font-size:24px;font-weight:500">${value}</div></div>`;
  // Prompts go through a JSON island so titles with quotes cannot break the script.
  const prompts = { refresh: L.askRefresh, unload: Object.fromEntries(sessions.map(s => [s.pid, L.askUnload(s.title, s.pid, s.status === 'busy')])) };

  const rows = sessions.map(s => {
    const action = s.current
      ? `<span class="m">${L.current}</span>`
      : `<button data-pid="${s.pid}">${s.status === 'busy' ? L.interrupt : L.unload} ↗</button>`;
    return `<div class="row">
  <div style="min-width:0"><div class="t" title="${esc(s.title)}">${esc(s.title)}</div><div class="m">${esc(s.cwd)}</div></div>
  <div><div style="font-size:13px">${size(s.memBytes)} · ${s.processCount} ${L.proc}</div><div class="bar"><i style="width:${Math.max(2, Math.round(s.memBytes / max * 100))}%"></i></div></div>
  <span class="pill ${s.status === 'busy' ? 'busy' : 'idle'}">${s.status === 'busy' ? L.busy : L.idle}</span>
  ${action}
</div>`;
  }).join('\n');

  return `<h2 class="sr-only">${esc(L.inSessions)}: ${size(total)}, ${sessions.length} Claude Code sessions.</h2>
<style>
.row{display:grid;grid-template-columns:minmax(0,1fr) 150px 72px 104px;gap:12px;align-items:center;padding:10px 0;border-bottom:0.5px solid var(--border)}
.row:last-child{border-bottom:0}
.t{font-size:14px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.m{font-size:12px;color:var(--text-secondary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar{height:6px;border-radius:3px;background:var(--surface-1);overflow:hidden;margin-top:4px}
.bar i{display:block;height:100%;background:var(--text-accent);border-radius:3px}
.pill{font-size:12px;padding:2px 8px;border-radius:var(--radius);justify-self:start}
.idle{background:var(--bg-success);color:var(--text-success)}
.busy{background:var(--bg-warning);color:var(--text-warning)}
@media (max-width:520px){.row{grid-template-columns:minmax(0,1fr) 96px}.row .pill{display:none}}
</style>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:0.5rem 0 1rem">
${stat(L.inSessions, size(total))}
${stat(L.counts, `${sessions.length} / ${procs}`)}
${app ? stat(L.app, size(app.memBytes)) : ''}
</div>
<div id="sr-rows">${rows || `<p class="m">${L.none}</p>`}</div>
<div style="display:flex;justify-content:space-between;align-items:center;margin-top:12px">
  <span class="m">${L.asOf} ${time}</span>
  <button id="sr-refresh">${L.refresh} ↗</button>
</div>
<script type="application/json" id="sr-prompts">${JSON.stringify(prompts).replace(/</g, '\\u003c')}</script>
<script>
const P = JSON.parse(document.getElementById('sr-prompts').textContent);
document.getElementById('sr-refresh').onclick = () => sendPrompt(P.refresh);
document.getElementById('sr-rows').addEventListener('click', e => {
  const b = e.target.closest('button[data-pid]');
  if (b) sendPrompt(P.unload[b.dataset.pid]);
});
</script>`;
}

// ---------------------------------------------------------------- menu bar (macOS, Linux)

// Output in the xbar plugin format, read by xbar and SwiftBar on macOS and by
// Argos (GNOME) and Kargos (KDE) on Linux. Unload items call `confirm-unload`,
// which asks with a native dialog before anything stops.
function xbarOutput(data) {
  const ru = /^ru/i.test(process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || Intl.DateTimeFormat().resolvedOptions().locale || '');
  const L = ru
    ? { sessions: 'Сессии Claude Code', unload: 'Выгрузить…', busy: 'работает', idle: 'ждёт', app: 'Само приложение Claude',
        dashboard: 'Открыть панель', refresh: 'Обновить', none: 'Запущенных сессий нет', gb: 'ГБ', mb: 'МБ', ram: 'RAM', procs: 'процессов', interrupt: 'Прервать и выгрузить…' }
    : { sessions: 'Claude Code sessions', unload: 'Unload…', busy: 'busy', idle: 'idle', app: 'Claude app itself',
        dashboard: 'Open dashboard', refresh: 'Refresh', none: 'No running sessions', gb: 'GB', mb: 'MB', ram: 'RAM', procs: 'processes', interrupt: 'Interrupt and unload…' };
  const size = b => b >= 1073741824 ? `${(b / 1073741824).toFixed(1)} ${L.gb}` : `${Math.round(b / 1048576)} ${L.mb}`;
  // "|" separates text from parameters in this format, and each item is one line.
  const clean = s => String(s ?? '').replace(/\|/g, '¦').replace(/[\r\n]+/g, ' ');
  const node = process.execPath;
  const self = fileURLToPath(import.meta.url);
  const run = (...argv) => process.platform === 'darwin'
    // xbar and SwiftBar: executable plus numbered parameters.
    ? `bash="${node}" ${[self, ...argv].map((a, i) => `param${i + 1}="${a}"`).join(' ')} terminal=false refresh=true`
    // Argos and Kargos: one command line.
    : `bash='"${node}" "${self}" ${argv.join(' ')}' terminal=false refresh=true`;

  const { sessions, app, systemMemBytes } = data;
  const total = sessions.reduce((t, s) => t + s.memBytes, 0);
  const share = systemMemBytes ? total / systemMemBytes : 0;
  const color = share >= 0.30 ? ' color=#d0433a' : share >= 0.15 ? ' color=#d28c14' : '';
  const lines = [`${size(total)} | sfimage=memorychip${color}`, '---',
    `${L.sessions}: ${sessions.length} · ${size(total)} (${Math.round(share * 100)}% ${L.ram}) | disabled=true`, '---'];
  if (!sessions.length) lines.push(`${L.none} | disabled=true`);
  for (const s of sessions) {
    lines.push(`${clean(s.title)} — ${size(s.memBytes)} · ${s.status === 'busy' ? L.busy : L.idle}`);
    lines.push(`--${clean(s.cwd)} | disabled=true`);
    lines.push(`--${s.processCount} ${L.procs}, PID ${s.pid} | disabled=true`);
    if (!s.current) lines.push(s.status === 'busy'
      ? `--${L.interrupt} | ${run('confirm-unload', String(s.pid), '--force')}`
      : `--${L.unload} | ${run('confirm-unload', String(s.pid))}`);
  }
  lines.push('---');
  if (app) lines.push(`${L.app}: ${size(app.memBytes)} | disabled=true`);
  lines.push(`${L.dashboard} | ${run('serve').replace(' refresh=true', '')}`);
  lines.push(`${L.refresh} | refresh=true`);
  return lines.join('\n');
}

// Native confirmation for menu bar clicks: osascript on macOS, zenity or
// kdialog on Linux. Refusals and results are shown the same way.
function confirmUnload(target, { force = false } = {}) {
  const preview = unloadSession(target, { force });
  const s = preview.session;
  const say = (msg, isError) => nativeMessage(msg, isError);
  if (!preview.ok) { say(`Session RAM: ${preview.error}`, true); process.exit(2); }

  const lines = [
    `Unload "${s.title}"?`, '',
    ...(s.status === 'busy' ? ['BUSY: the turn that is running now will be cut off. The conversation up to it is kept.', ''] : []),
    `Frees about ${mb(s.memBytes)} by stopping ${s.processCount} processes.`,
    ...s.children.filter(c => c.notable).map(c => `Also stops: ${c.cmd || c.name}`),
    '', 'The conversation stays in its transcript.', `To continue: ${preview.plan.resume}`,
  ];
  if (!nativeConfirm(lines.join('\n'))) return;
  const r = unloadSession(String(s.pid), { yes: true, force, expectSessionId: s.sessionId });
  say(r.ok ? `Unloaded "${s.title}", ~${mb(r.freedBytes)} freed.` : `Session RAM: ${r.error}`, !r.ok);
}

function which(bin) {
  try { execFileSync(IS_WIN ? 'where' : 'which', [bin], { stdio: 'ignore' }); return true; } catch { return false; }
}

function nativeConfirm(text) {
  try {
    if (process.platform === 'darwin') {
      execFileSync('osascript', ['-e', 'on run argv', '-e',
        'display dialog (item 1 of argv) with title "Session RAM" buttons {"Cancel", "Unload"} default button "Cancel" cancel button "Cancel" with icon caution',
        '-e', 'end run', text], { stdio: 'ignore' });
      return true;
    }
    if (which('zenity')) {
      const markup = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      execFileSync('zenity', ['--question', '--title=Session RAM', `--text=${markup}`, '--ok-label=Unload', '--cancel-label=Cancel', '--default-cancel'], { stdio: 'ignore' });
      return true;
    }
    if (which('kdialog')) {
      execFileSync('kdialog', ['--title', 'Session RAM', '--warningcontinuecancel', text, '--continue-label', 'Unload'], { stdio: 'ignore' });
      return true;
    }
  } catch { return false; } // Cancel exits non-zero.
  console.error('No dialog tool found (osascript, zenity or kdialog). Use "unload <pid>" from a terminal instead.');
  return false;
}

function nativeMessage(text, isError) {
  try {
    if (process.platform === 'darwin') {
      execFileSync('osascript', ['-e', 'on run argv', '-e', 'display notification (item 1 of argv) with title "Session RAM"', '-e', 'end run', text], { stdio: 'ignore' });
    } else if (which('notify-send')) {
      execFileSync('notify-send', [...(isError ? ['--urgency=critical'] : []), 'Session RAM', text], { stdio: 'ignore' });
    }
  } catch { /* the message is printed below as well */ }
  (isError ? console.error : console.log)(text);
}

// ---------------------------------------------------------------- setup

const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const TRAY_SCRIPT = path.join(PLUGIN_ROOT, 'companion', 'windows-tray', 'session-ram-tray.ps1');
const MENUBAR_SCRIPT = path.join(PLUGIN_ROOT, 'companion', 'menubar', 'session-ram.30s.sh');

// The tray's PID file survives a crash or sign-out, so a live PID alone is not
// proof: it must still be a PowerShell process.
function trayRunning(pid) {
  if (!pid || !alive(pid)) return false;
  try {
    const out = execFileSync('tasklist.exe', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8', windowsHide: true });
    return /^"powershell\.exe"/i.test(out.trim());
  } catch { return false; }
}

function trayState() {
  const dir = path.join(process.env.LOCALAPPDATA || path.join(HOME, 'AppData', 'Local'), 'session-ram');
  const pid = Number((() => { try { return fs.readFileSync(path.join(dir, 'tray.pid'), 'utf8').trim(); } catch { return ''; } })());
  const startup = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'Session RAM.lnk');
  return { running: trayRunning(pid), autostart: fs.existsSync(startup) };
}

// Menu bar apps that read xbar-format plugins, with their usual plugin folders.
function menubarApps() {
  const exists = p => { try { fs.accessSync(p); return true; } catch { return false; } };
  const apps = process.platform === 'darwin' ? [
    { name: 'SwiftBar', url: 'https://swiftbar.app', installed: exists('/Applications/SwiftBar.app'), folder: '~/Library/Application Support/SwiftBar/Plugins' },
    { name: 'xbar', url: 'https://xbarapp.com', installed: exists('/Applications/xbar.app'), folder: '~/Library/Application Support/xbar/plugins' },
  ] : process.platform === 'linux' ? [
    { name: 'Argos (GNOME)', url: 'https://github.com/p-e-w/argos', installed: exists(path.join(HOME, '.local/share/gnome-shell/extensions/argos@pew.worldwidemann.com')), folder: '~/.config/argos' },
    { name: 'Kargos (KDE)', url: 'https://github.com/lipido/kargos', installed: exists(path.join(HOME, '.local/share/plasma/plasmoids/org.kde.kargos')), folder: '~/.config/kargos' },
  ] : [];
  return apps.map(a => ({ ...a, command: `mkdir -p "${a.folder.replace('~', '$HOME')}" && ln -sf "${MENUBAR_SCRIPT}" "${a.folder.replace('~', '$HOME')}/session-ram.30s.sh"` }));
}

function setupStatus() {
  const major = Number(process.versions.node.split('.')[0]);
  return {
    platform: process.platform,
    node: { version: process.version, ok: major >= 18 },
    tray: IS_WIN ? trayState() : null,
    menubar: IS_WIN ? null : menubarApps(),
  };
}

// Started through `cmd /c start`, whose cmd exits at once, so the tray is not a
// child of this server. Otherwise, when the server runs inside a session, the
// tray would count toward that session and die when it is unloaded.
function startTray() {
  spawn('cmd.exe', ['/d /c start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + TRAY_SCRIPT + '"'],
    { detached: true, stdio: 'ignore', windowsHide: true, windowsVerbatimArguments: true }).unref();
}

function setAutostart(on) {
  execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', TRAY_SCRIPT, '-Autostart', on ? 'on' : 'off'],
    { stdio: 'ignore', windowsHide: true });
}

// ---------------------------------------------------------------- dashboard

// A local web page with the same list and an Unload button. It listens on
// 127.0.0.1 only, and every request must carry a random token, so neither
// other machines nor other websites open in the browser can use it.
// Opens the dashboard as a standalone app window (Chromium's --app mode: no
// tabs or address bar) when Edge or Chrome is installed, else in the default browser.
function openWindow(link, { appWindow }) {
  const exists = p => { try { return fs.statSync(p).isFile(); } catch { return false; } };
  let bin, argv;
  if (IS_WIN) {
    const pf = [process.env['ProgramFiles(x86)'], process.env.ProgramFiles, process.env.LOCALAPPDATA].filter(Boolean);
    const browser = appWindow && pf.flatMap(d => [
      path.join(d, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      path.join(d, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    ]).find(exists);
    [bin, argv] = browser ? [browser, [`--app=${link}`, '--window-size=900,640']] : ['cmd.exe', ['/c', 'start', '""', link]];
  } else if (process.platform === 'darwin') {
    const chrome = '/Applications/Google Chrome.app';
    [bin, argv] = appWindow && fs.existsSync(chrome) ? ['open', ['-na', chrome, '--args', `--app=${link}`]] : ['open', [link]];
  } else {
    [bin, argv] = ['xdg-open', [link]];
  }
  try {
    const child = spawn(bin, argv, { detached: true, stdio: 'ignore', windowsHide: bin === 'cmd.exe', windowsVerbatimArguments: bin === 'cmd.exe' });
    child.on('error', () => { /* the link is printed anyway */ });
    child.unref();
  } catch { /* the link is printed anyway */ }
}

async function serve({ port = 0, open = true, asTab = false, keep = false, page = '' }) {
  const http = await import('node:http');
  const crypto = await import('node:crypto');
  const token = crypto.randomBytes(16).toString('hex');
  const htmlPath = path.join(PLUGIN_ROOT, 'skills', 'session-ram', 'scripts', 'dashboard.html');
  const IDLE_EXIT_MS = 15 * 60 * 1000;
  let lastSeen = Date.now();
  let cache = null;

  const listSessions = () => {
    // The Windows process query takes a couple of seconds; share it between tabs.
    if (!cache || Date.now() - cache.at > 3000) cache = { at: Date.now(), data: collect() };
    return cache.data;
  };
  const send = (res, code, body, type = 'application/json; charset=utf-8') => {
    res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' });
    res.end(typeof body === 'string' ? body : JSON.stringify(body));
  };

  const server = http.createServer((req, res) => {
    const addr = server.address();
    const url = new URL(req.url, `http://127.0.0.1:${addr.port}`);
    // Reject DNS-rebinding requests that reach us under a foreign host name.
    if (req.headers.host !== `127.0.0.1:${addr.port}` && req.headers.host !== `localhost:${addr.port}`) return send(res, 403, { error: 'bad host' });
    lastSeen = Date.now();

    if (req.method === 'GET' && url.pathname === '/') {
      if (url.searchParams.get('t') !== token) return send(res, 403, 'Forbidden: open the link printed by session-ram.', 'text/plain; charset=utf-8');
      const html = fs.readFileSync(htmlPath, 'utf8').replace('__TOKEN__', token);
      return send(res, 200, html, 'text/html; charset=utf-8');
    }
    // API calls must send the token in a header, which a cross-site page cannot do without CORS.
    if (req.headers['x-session-ram-token'] !== token) return send(res, 403, { error: 'bad token' });

    try {
      if (req.method === 'GET' && url.pathname === '/api/sessions') return send(res, 200, listSessions());
      if (req.method === 'GET' && url.pathname === '/api/setup') return send(res, 200, setupStatus());
      if (req.method === 'POST' && url.pathname === '/api/setup/tray' && IS_WIN) {
        startTray();
        return send(res, 200, { ok: true });
      }
      if (req.method === 'POST' && (url.pathname === '/api/setup/autostart-on' || url.pathname === '/api/setup/autostart-off') && IS_WIN) {
        setAutostart(url.pathname.endsWith('-on'));
        return send(res, 200, { ok: true, ...trayState() });
      }
      if (req.method === 'POST' && url.pathname === '/api/unload') {
        let body = '';
        req.on('data', c => { body += c; if (body.length > 10000) req.destroy(); });
        req.on('end', () => {
          try {
            const { pid, sessionId, force } = JSON.parse(body || '{}');
            if (!Number.isInteger(pid) || typeof sessionId !== 'string') return send(res, 400, { ok: false, error: 'pid and sessionId required' });
            const r = unloadSession(String(pid), { yes: true, force: force === true, expectSessionId: sessionId });
            delete r.session;
            cache = null;
            send(res, r.ok ? 200 : 409, r);
          } catch (e) { send(res, 500, { ok: false, error: e.message }); }
        });
        return;
      }
      send(res, 404, { error: 'not found' });
    } catch (e) { send(res, 500, { error: e.message }); }
  });

  await new Promise((ok, fail) => { server.once('error', fail); server.listen(port, '127.0.0.1', ok); });
  const link = `http://127.0.0.1:${server.address().port}/?t=${token}${page ? `#${page}` : ''}`;
  console.log(`Session RAM dashboard: ${link}`);
  console.log(keep ? 'It keeps running until you press Ctrl+C.' : 'It stops by itself 15 minutes after the page is closed. Press Ctrl+C to stop now.');

  if (open) openWindow(link, { appWindow: !asTab });
  if (!keep) setInterval(() => { if (Date.now() - lastSeen > IDLE_EXIT_MS) process.exit(0); }, 30000).unref();
}

// ---------------------------------------------------------------- main

const args = process.argv.slice(2);
const flags = new Set(args.filter(a => a.startsWith('--')));
const pos = args.filter(a => !a.startsWith('--'));
const cmd = pos[0] || 'list';
const portArg = args.find(a => a.startsWith('--port='));

try {
  if (cmd === 'list') {
    const data = collect();
    if (flags.has('--json')) console.log(JSON.stringify(data, null, 2)); else printList(data);
  } else if (cmd === 'unload') {
    if (!pos[1]) throw new Error('usage: unload <pid|session-id-prefix> [--expect=<session-id>] [--yes] [--force] [--json]');
    const expect = args.find(a => a.startsWith('--expect='));
    unloadCli(pos[1], { yes: flags.has('--yes'), force: flags.has('--force'), json: flags.has('--json'),
      expectSessionId: expect ? expect.slice('--expect='.length) : null });
  } else if (cmd === 'widget') {
    const lang = (args.find(a => a.startsWith('--lang=')) || '--lang=en').split('=')[1];
    console.log(widgetHtml(collect(), lang));
  } else if (cmd === 'xbar') {
    console.log(xbarOutput(collect()));
  } else if (cmd === 'confirm-unload') {
    if (!pos[1]) throw new Error('usage: confirm-unload <pid>');
    confirmUnload(pos[1], { force: flags.has('--force') });
  } else if (cmd === 'serve') {
    await serve({ port: portArg ? Number(portArg.split('=')[1]) : 0, open: !flags.has('--no-open'), asTab: flags.has('--tab'), keep: flags.has('--keep'), page: flags.has('--setup') ? 'setup' : '' });
  } else {
    throw new Error(`unknown command "${cmd}". Use "list", "unload" or "serve".`);
  }
} catch (e) {
  console.error(e.message);
  process.exit(2);
}
