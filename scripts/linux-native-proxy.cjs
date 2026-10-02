'use strict';

// Configure only the private copy of CC Switch's upstream proxy settings.
// Schema: farion1231/cc-switch v3.20.4, database/schema.rs and dao/proxy.rs.
// No provider credentials are changed, and no saved host loopback URL is trusted.
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');

function plainPath(p) {
  let current = path.resolve(p);
  for (;;) {
    try { if (fs.lstatSync(current).isSymbolicLink()) throw Error('Native proxy path contains a symbolic link.'); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    const parent = path.dirname(current); if (parent === current) break; current = parent;
  }
}
function identity(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) throw Error('Invalid manager process identity.');
  const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  const fields = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
  return { pid, ppid: Number(fields[1]), start: fields[19], boot: fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim() };
}
function descendants(owner, limit = 4096) {
  const found = new Map([[owner.pid, owner]]), pending = [owner];
  while (pending.length) {
    const parent = pending.pop(), pid = parent.pid;
    if (found.size >= limit) throw Error('Manager process tree exceeds ownership inspection limits.');
    let children;
    try { children = fs.readFileSync(`/proc/${pid}/task/${pid}/children`, 'utf8').trim().split(/\s+/); }
    catch { throw Error('Cannot verify the manager process tree.'); }
    for (const id of children) {
      if (!/^\d+$/.test(id)) continue;
      const child = identity(Number(id));
      if (child.ppid !== pid || child.boot !== owner.boot) throw Error('Cannot verify the manager process tree.');
      const previous = found.get(child.pid);
      if (previous && (previous.start !== child.start || previous.ppid !== child.ppid)) throw Error('Manager process tree changed during inspection.');
      if (!previous) { found.set(child.pid, child); pending.push(child); }
    }
  }
  return found;
}
function stillDescendsFrom(snapshot, owner) {
  let current = snapshot;
  for (let depth = 0; depth < 4096; depth++) {
    let live;
    try { live = identity(current.pid); } catch { return false; }
    if (live.start !== current.start || live.boot !== current.boot || live.ppid !== current.ppid) return false;
    if (live.pid === owner.pid) return live.start === owner.start && live.boot === owner.boot;
    if (live.ppid < 1) return false;
    current = { pid: live.ppid };
    try {
      const parent = identity(current.pid);
      current = parent;
    } catch { return false; }
    // Recheck the child after reading its parent so a reparenting race cannot
    // turn an unrelated process with a reused PID into an accepted descendant.
    let childAgain;
    try { childAgain = identity(live.pid); } catch { return false; }
    if (childAgain.start !== live.start || childAgain.boot !== live.boot || childAgain.ppid !== live.ppid) return false;
    if (current.pid === owner.pid) return current.start === owner.start && current.boot === owner.boot;
  }
  return false;
}
function ownedListener(port, owner) {
  const now = identity(owner.pid);
  if (now.start !== owner.start || now.boot !== owner.boot) return false;
  const wanted = port.toString(16).toUpperCase().padStart(4, '0'), inodes = new Set();
  const rows = fs.readFileSync('/proc/net/tcp', 'utf8').trim().split('\n').slice(1);
  for (const line of rows) {
    const fields = line.trim().split(/\s+/);
    if (fields[1] === `0100007F:${wanted}` && fields[3] === '0A') inodes.add(fields[9]);
  }
  if (!inodes.size) return false;
  for (const [pid, processIdentity] of descendants(owner)) {
    let names;
    try { names = fs.readdirSync(`/proc/${pid}/fd`); }
    catch { return false; }
    for (const name of names) {
      let target;
      try { target = fs.readlinkSync(`/proc/${pid}/fd/${name}`); } catch { return false; }
      const m = /^socket:\[(\d+)\]$/.exec(target);
      if (m && inodes.has(m[1]) && stillDescendsFrom(processIdentity, owner)) return true;
    }
  }
  return false;
}

// Upstream creates the remaining database tables and runs its own migrations.
// All proxy rows share the global listener; keep upstream's per-app defaults.
const SCHEMA = `CREATE TABLE IF NOT EXISTS proxy_config (
 app_type TEXT PRIMARY KEY CHECK (app_type IN ('claude','codex','gemini','grokbuild')),
 proxy_enabled INTEGER NOT NULL DEFAULT 0, listen_address TEXT NOT NULL DEFAULT '127.0.0.1',
 listen_port INTEGER NOT NULL DEFAULT 15721, enable_logging INTEGER NOT NULL DEFAULT 1,
 enabled INTEGER NOT NULL DEFAULT 0, auto_failover_enabled INTEGER NOT NULL DEFAULT 0,
 max_retries INTEGER NOT NULL DEFAULT 3, streaming_first_byte_timeout INTEGER NOT NULL DEFAULT 60,
 streaming_idle_timeout INTEGER NOT NULL DEFAULT 120, non_streaming_timeout INTEGER NOT NULL DEFAULT 600,
 circuit_failure_threshold INTEGER NOT NULL DEFAULT 4, circuit_success_threshold INTEGER NOT NULL DEFAULT 2,
 circuit_timeout_seconds INTEGER NOT NULL DEFAULT 60, circuit_error_rate_threshold REAL NOT NULL DEFAULT 0.6,
 circuit_min_requests INTEGER NOT NULL DEFAULT 10, default_cost_multiplier TEXT NOT NULL DEFAULT '1',
 pricing_model_source TEXT NOT NULL DEFAULT 'response', live_takeover_active INTEGER NOT NULL DEFAULT 0,
 created_at TEXT NOT NULL DEFAULT (datetime('now')), updated_at TEXT NOT NULL DEFAULT (datetime('now'))
)`;
function database(p, readOnly = false) {
  plainPath(p);
  if (fs.existsSync(p) && (!fs.lstatSync(p).isFile() || fs.statSync(p).size > 32 * 1024 * 1024)) throw Error('Private CC Switch database is invalid or too large.');
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(p, { readOnly }); db.exec('PRAGMA busy_timeout=1500'); return db;
}
async function prepareNativeProxy({ sessionRoot, network }) {
  if (process.platform !== 'linux') throw Error('Native proxy isolation requires Linux.');
  if (typeof network !== 'boolean') throw Error('Native proxy network mode must be explicit.');
  sessionRoot = path.resolve(sessionRoot); plainPath(sessionRoot);
  const st = fs.lstatSync(sessionRoot);
  if (!st.isDirectory() || st.uid !== process.getuid() || (st.mode & 0o077)) throw Error('Native proxy requires a private user-owned session directory.');
  const reservation = net.createServer();
  await new Promise((resolve, reject) => { reservation.once('error', reject); reservation.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve); });
  const port = reservation.address().port;
  const dbPath = path.join(sessionRoot, 'config', 'cc-switch', 'home', '.cc-switch', 'cc-switch.db');
  try {
    plainPath(path.dirname(dbPath)); fs.mkdirSync(path.dirname(dbPath), { recursive: true, mode: 0o700 });
    const db = database(dbPath);
    let originalListeners;
    try {
      db.exec(SCHEMA);
      db.exec(`INSERT OR IGNORE INTO proxy_config(app_type,max_retries,streaming_first_byte_timeout,streaming_idle_timeout,circuit_failure_threshold,circuit_success_threshold,circuit_timeout_seconds,circuit_error_rate_threshold,circuit_min_requests) VALUES ('claude',6,90,180,8,3,90,0.7,15)`);
      for (const name of ['codex', 'gemini', 'grokbuild']) db.prepare('INSERT OR IGNORE INTO proxy_config(app_type) VALUES (?)').run(name);
      originalListeners = db.prepare('SELECT app_type,listen_address,listen_port FROM proxy_config').all();
      // Offline isolation happens at the network namespace, preserving the
      // user's proxy preference for their next online session.
      db.prepare('UPDATE proxy_config SET listen_address=?,listen_port=?, updated_at=datetime(\'now\')').run('127.0.0.1', port);
    } finally { db.close(); }
    fs.chmodSync(dbPath, 0o600);
    return { sessionRoot, dbPath, network, port, reservation, originalListeners, owner: null, closed: false };
  } catch (e) { await new Promise(resolve => reservation.close(resolve)); throw e; }
}
async function releaseReservation(state) {
  if (!state?.reservation) return;
  const server = state.reservation; state.reservation = null;
  await new Promise(resolve => server.close(resolve));
}
function attachManager(state, childPid) {
  if (!state || state.closed) throw Error('Native proxy manager session is closed.');
  state.owner = identity(childPid);
}
async function asNativeProvider(state, provider, childPid) {
  if (provider.mode !== 'proxy-managed') return provider;
  if (!state || state.closed || !state.network) throw Error('原生代理需要此 U 盘的联网 CC Switch 窗口。');
  if (!state.owner || state.owner.pid !== childPid) throw Error('Native proxy manager process is not registered.');
  const db = database(state.dbPath, true);
  let row;
  try { row = db.prepare("SELECT listen_address,listen_port,proxy_enabled FROM proxy_config WHERE app_type='claude'").get(); }
  finally { db.close(); }
  if (!row || row.listen_address !== '127.0.0.1' || row.listen_port !== state.port || !row.proxy_enabled) throw Error('请在当前 U 盘 CC Switch 中启动原生代理，并保留此会话的独立端口。');
  if (!ownedListener(state.port, state.owner)) throw Error('原生代理尚未就绪，或监听进程不属于此 U 盘 CC Switch；未连接本机代理。');
  return { ...provider, mode: 'managed-native-proxy', baseUrl: `http://127.0.0.1:${state.port}`, secret: 'PROXY_MANAGED', authEnvironmentName: 'ANTHROPIC_AUTH_TOKEN' };
}
async function closeNativeProxy(state) { if (!state) return; state.closed = true; await releaseReservation(state); }
function restorePortableProxySettings(state) {
  if (!state || !state.originalListeners) return;
  const db = database(state.dbPath);
  try {
    db.exec('BEGIN IMMEDIATE');
    const update = db.prepare('UPDATE proxy_config SET listen_address=?,listen_port=? WHERE app_type=?');
    for (const original of state.originalListeners) update.run(original.listen_address, original.listen_port, original.app_type);
    db.exec('COMMIT');
  } catch (e) { try { db.exec('ROLLBACK'); } catch {} throw e; }
  finally { db.close(); }
}
module.exports = { prepareNativeProxy, releaseReservation, attachManager, asNativeProvider, closeNativeProxy, restorePortableProxySettings, ownedListener };
