'use strict';

// Integration against only bundled official binaries and synthetic local
// Anthropic-compatible endpoints. No user config, API key, or real request is
// read or sent. Pass --gui with an isolated DISPLAY to exercise the upstream
// AppImage and manager-owned native proxy as well as the real Claude CLI.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const { DatabaseSync } = require('node:sqlite');
const runtimeApi = require('./linux-runtime.cjs');
const sandboxApi = require('./linux-sandbox.cjs');
const sessionApi = require('./linux-session.cjs');
const nativeProxy = require('./linux-native-proxy.cjs');

function processIdentity(pid) {
  const raw = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'), fields = raw.slice(raw.lastIndexOf(')') + 2).trim().split(/\s+/);
  return { pid, start: fields[19], pgid: Number(fields[2]), boot: fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim() };
}
function sameLeader(owner) {
  try { const now = processIdentity(owner.pid); return now.start === owner.start && now.pgid === owner.pgid && now.pgid === now.pid && now.boot === owner.boot; }
  catch { return false; }
}
function runOwned(config, timeoutMs = 60000) {
  const child = sandboxApi.launchSandbox(config, { stdio: ['ignore', 'pipe', 'pipe'] });
  const owner = processIdentity(child.pid);
  let stdout = '', stderr = '';
  child.stdout?.on('data', (b) => { stdout += b.toString(); });
  child.stderr?.on('data', (b) => { stderr += b.toString(); });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null && sameLeader(owner)) { try { process.kill(-owner.pgid, 'SIGTERM'); } catch {} }
      setTimeout(() => { if (child.exitCode === null && child.signalCode === null && sameLeader(owner)) { try { process.kill(-owner.pgid, 'SIGKILL'); } catch {} } }, 1500).unref();
      reject(new Error('synthetic Claude CLI integration timed out'));
    }, timeoutMs);
    child.once('error', (e) => { clearTimeout(timer); reject(e); });
    child.once('exit', (code, signal) => { clearTimeout(timer); resolve({ code, signal, stdout, stderr }); });
  });
}
async function listen(server, port = 0) {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return server.address().port;
}
async function canConnectLocal(port) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    socket.once('connect', () => { socket.destroy(); resolve(true); });
    socket.once('error', () => resolve(false));
  });
}
function readTcpListener(port) {
  try {
    const wanted = port.toString(16).toUpperCase().padStart(4, '0');
    return fs.readFileSync('/proc/net/tcp', 'utf8').split('\n').slice(1).some((line) => {
      const fields = line.trim().split(/\s+/); return fields[1] === `0100007F:${wanted}` && fields[3] === '0A';
    });
  } catch { return false; }
}
async function testPythonEnvironment(root, parent) {
  const projects = ['native-exec', 'fat-noexec'].map((name) => { const dir = path.join(parent, name); fs.mkdirSync(dir, { mode: 0o700 }); return dir; });
  const layouts = [
    sessionApi.pythonEnvironmentLayout(root, projects[0], `601 1 8:1 / ${projects[0]} rw - ext4 /dev/synthetic rw`),
    sessionApi.pythonEnvironmentLayout(root, projects[1], `602 1 8:2 / ${projects[1]} rw,nosuid,nodev,noexec - vfat /dev/synthetic rw`),
  ];
  assert.equal(layouts[0].privateEnvironment, false);
  assert.equal(layouts[1].privateEnvironment, true);
  try {
  const stage = path.join(parent, 'python-test-stage'); fs.mkdirSync(stage, { mode: 0o700 });
  const staged = runtimeApi.stagePython(root, stage);
  const stagedPythonRoot = path.join(stage, 'python-stage', 'python');
  try {
    for (let i = 0; i < layouts.length; i++) {
      const layout = layouts[i];
      if (fs.existsSync(layout.stableRoot) || fs.existsSync(layout.venv)) throw new Error('synthetic Python integration paths unexpectedly exist');
      fs.mkdirSync(path.dirname(layout.stableRoot), { recursive: true, mode: 0o700 });
      if (layout.privateEnvironment) { fs.mkdirSync(layout.cacheRoot, { recursive: true, mode: 0o700 }); fs.chmodSync(layout.cacheRoot, 0o700); }
      fs.cpSync(stagedPythonRoot, layout.stableRoot, { recursive: true, dereference: false, verbatimSymlinks: true, errorOnExist: true });
      const stablePython = path.join(layout.stableRoot, path.relative(stagedPythonRoot, staged.python));
      const create = require('node:child_process').spawnSync(staged.uv, ['venv', '--no-config', '--no-project', '--python', stablePython, layout.venv], {
        cwd: projects[i], encoding: 'utf8', timeout: 120000,
        env: { PATH: `${path.dirname(staged.uv)}:/usr/bin:/bin`, HOME: path.join(parent, 'python-home'), UV_NO_CONFIG: '1', UV_NO_PROJECT: '1', UV_LINK_MODE: 'copy' },
      });
      assert.equal(create.status, 0, `uv failed to create ${layout.privateEnvironment ? 'FAT/noexec private' : 'native project'} environment: ${create.stderr}`);
    }
  } finally { fs.rmSync(stage, { recursive: true, force: true }); }
  for (let i = 0; i < layouts.length; i++) {
    const check = require('node:child_process').spawnSync(path.join(layouts[i].venv, 'bin', 'python'), ['--version'], { encoding: 'utf8', timeout: 30000, env: { PATH: '/usr/bin:/bin', HOME: path.join(parent, 'python-home') } });
    assert.equal(check.status, 0, `Python environment ${i} must remain runnable after temporary staging is removed`);
  }
  console.log('Bundled Python/uv created and verified project and FAT/noexec-managed environments after staging cleanup.');
  } finally {
    for (const layout of layouts) if (layout.privateEnvironment && fs.existsSync(layout.cacheRoot)) fs.rmSync(layout.cacheRoot, { recursive: true, force: true });
  }
}
async function runGuiProxyIntegration(runtime, sessionRoot, workDir, syntheticPort, providerServer) {
  // Match runCcSwitch: localize the app's per-harness config before start and
  // seed its live Claude configuration with only synthetic credentials.
  sessionApi.localizeCcSwitchSettings(sessionRoot);
  const liveSettings = path.join(runtime.claudeConfig, 'settings.json');
  fs.mkdirSync(path.dirname(liveSettings), { recursive: true, mode: 0o700 });
  fs.writeFileSync(liveSettings, JSON.stringify({ env: {
    ANTHROPIC_BASE_URL: `http://127.0.0.1:${syntheticPort}/gateway`,
    ANTHROPIC_AUTH_TOKEN: 'synthetic-native-proxy-token-only',
    ANTHROPIC_MODEL: 'sonnet',
  } }), { mode: 0o600 });
  const state = await nativeProxy.prepareNativeProxy({ sessionRoot, network: true });
  const db = new DatabaseSync(state.dbPath);
  db.exec('PRAGMA busy_timeout=5000');
  try {
    db.exec(`CREATE TABLE IF NOT EXISTS providers (
      id TEXT NOT NULL, app_type TEXT NOT NULL, name TEXT NOT NULL, settings_config TEXT NOT NULL,
      website_url TEXT, category TEXT, created_at INTEGER, sort_index INTEGER, notes TEXT, icon TEXT, icon_color TEXT,
      meta TEXT NOT NULL DEFAULT '{}', is_current BOOLEAN NOT NULL DEFAULT 0, in_failover_queue BOOLEAN NOT NULL DEFAULT 0,
      PRIMARY KEY (id, app_type))`);
    db.prepare(`INSERT OR REPLACE INTO providers(id,app_type,name,settings_config,meta,is_current,in_failover_queue)
      VALUES(?,?,?,?,?,1,0)`).run('synthetic-portable-integration', 'claude', 'Synthetic local provider', JSON.stringify({
      env: { ANTHROPIC_BASE_URL: `http://127.0.0.1:${syntheticPort}/gateway`, ANTHROPIC_AUTH_TOKEN: 'synthetic-native-proxy-token-only', ANTHROPIC_MODEL: 'sonnet' },
    }), '{}');
    db.prepare("UPDATE proxy_config SET proxy_enabled=1,enabled=1 WHERE app_type='claude'").run();
  } finally { db.close(); }

  let existing15721 = null, external15721 = false, manager = null, managerIdentity = null, error = null, managerLog = '';
  try {
    existing15721 = http.createServer((_req, res) => res.writeHead(204).end());
    await listen(existing15721, 15721);
  } catch (e) {
    if (existing15721?.listening) await new Promise((resolve) => existing15721.close(resolve)); existing15721 = null;
    if (e.code !== 'EADDRINUSE' || !await canConnectLocal(15721)) throw new Error('Cannot establish an existing 127.0.0.1:15721 service fixture.');
    external15721 = true;
  }
  const initialRequests = providerServer.requests || 0;
  try {
    await nativeProxy.releaseReservation(state);
    const config = sandboxApi.buildSandbox({ sessionRoot, runtime, mode: 'cc-switch', command: runtime.ccSwitch, args: [], workDir: runtime.workDir, network: true });
    manager = sandboxApi.launchSandbox(config, { stdio: ['ignore', 'pipe', 'pipe'] });
    if (!manager || !Number.isSafeInteger(manager.pid)) throw new Error('sandbox did not start an owned CC Switch process');
    const logChunk = (chunk) => {
      managerLog = (managerLog + chunk.toString('utf8')).slice(-64 * 1024);
      managerLog = managerLog.replace(/synthetic-(?:native-proxy-token-only|integration-token-only|broker-secret|pty-password)/g, '[synthetic secret redacted]');
    };
    manager.stdout?.on('data', logChunk); manager.stderr?.on('data', logChunk);
    managerIdentity = processIdentity(manager.pid);
    nativeProxy.attachManager(state, manager.pid);
    let ready = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (manager.exitCode !== null || manager.signalCode !== null) throw new Error('CC Switch GUI exited before its native proxy became ready');
      if (nativeProxy.ownedListener(state.port, state.owner)) { ready = true; break; }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    if (!ready) {
      let row = null, provider = null, tableNames = [];
      try {
        const diagnosticDb = new DatabaseSync(state.dbPath, { readOnly: true });
        diagnosticDb.exec('PRAGMA busy_timeout=5000');
        try {
          row = diagnosticDb.prepare("SELECT app_type,listen_address,listen_port,proxy_enabled,enabled,live_takeover_active FROM proxy_config WHERE app_type='claude'").get();
          provider = diagnosticDb.prepare("SELECT id,app_type,is_current FROM providers WHERE app_type='claude' AND id='synthetic-portable-integration'").get();
          tableNames = diagnosticDb.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map((r) => r.name);
        } finally { diagnosticDb.close(); }
      } catch (e) { row = { diagnosticError: e.message }; }
      throw new Error(`CC Switch GUI did not start its native proxy; db=${JSON.stringify({ row, provider, tables: tableNames })}; tcpListening=${readTcpListener(state.port)}; localConnect=${await canConnectLocal(state.port)}; ownedListener=${nativeProxy.ownedListener(state.port, state.owner)}; manager=${JSON.stringify({ pid: manager.pid, exitCode: manager.exitCode, signalCode: manager.signalCode })}; logs=${managerLog}`);
    }
    const activeDb = new DatabaseSync(state.dbPath, { readOnly: true });
    activeDb.exec('PRAGMA busy_timeout=5000');
    try {
      assert.ok(activeDb.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='providers'").get(), 'actual GUI startup should retain the synthetic provider table');
      const provider = activeDb.prepare("SELECT id,is_current FROM providers WHERE app_type='claude' AND id='synthetic-portable-integration'").get();
      assert.equal(provider?.is_current, 1, 'CC Switch should retain the private synthetic current provider');
    } finally { activeDb.close(); }
    const liveProvider = await nativeProxy.asNativeProvider(state, { mode: 'proxy-managed', name: 'synthetic integration', models: { ANTHROPIC_MODEL: 'sonnet' } }, manager.pid);
    assert.equal(new URL(liveProvider.baseUrl).port, String(state.port));
    assert.equal(liveProvider.secret, 'PROXY_MANAGED');
    await sessionApi.testProvider(liveProvider);
    assert.ok((providerServer.requests || 0) > initialRequests, 'CC Switch owned listener must forward a real synthetic Messages request');
    assert.equal(providerServer.observedAuth, 'synthetic-native-proxy-token-only', 'only the local synthetic receiver may see the synthetic upstream token');
    const managerRequestCount = providerServer.requests;
    const providerEnvironment = { ANTHROPIC_BASE_URL: liveProvider.baseUrl };
    providerEnvironment[liveProvider.authEnvironmentName] = liveProvider.secret;
    for (const [key, value] of Object.entries(liveProvider.models || {})) providerEnvironment[key] = String(value);
    const claudeRun = await runOwned(sandboxApi.buildSandbox({
      sessionRoot, runtime, mode: 'claude', command: runtime.claude,
      args: ['--print', '--output-format', 'text', '--model', 'sonnet', 'Reply with exactly synthetic-ok.'],
      workDir, network: true, extraEnv: providerEnvironment,
    }));
    assert.equal(claudeRun.code, 0, `Claude CLI through the live CC Switch proxy failed: ${claudeRun.stderr || claudeRun.stdout}`);
    assert.match(claudeRun.stdout, /synthetic-ok/, 'Claude CLI should consume the synthetic SSE reply');
    assert.ok(providerServer.requests > managerRequestCount && providerServer.requests <= 8, 'Claude CLI should make bounded Messages requests through the live proxy');
    assert.equal(providerServer.observedAuth, 'synthetic-native-proxy-token-only', 'Claude requests must reach only the local receiver with its synthetic upstream token');
    if (existing15721) {
      const responseStatus = await new Promise((resolve, reject) => {
        const req = http.get('http://127.0.0.1:15721/', (res) => { res.resume(); res.once('end', () => resolve(res.statusCode)); });
        req.once('error', reject);
      });
      assert.equal(responseStatus, 204, 'existing conventional host port must remain owned and unchanged');
    }
    if (external15721) assert.equal(await canConnectLocal(15721), true, 'pre-existing conventional host listener must remain reachable and untouched');
    console.log(`Actual CC Switch GUI PID ${manager.pid} owned port ${state.port}; both the native proxy probe and Claude CLI used its synthetic upstream.`);
  } catch (e) { error = e; }
  finally {
    if (manager && manager.exitCode === null && manager.signalCode === null && managerIdentity && sameLeader(managerIdentity)) {
      try { process.kill(-managerIdentity.pgid, 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') error ||= e; }
      const until = Date.now() + 4000;
      while (manager.exitCode === null && manager.signalCode === null && Date.now() < until) await new Promise((resolve) => setTimeout(resolve, 100));
      if (manager.exitCode === null && manager.signalCode === null && sameLeader(managerIdentity)) {
        try { process.kill(-managerIdentity.pgid, 'SIGKILL'); } catch {}
      }
      if (manager.exitCode === null && manager.signalCode === null) await Promise.race([new Promise((resolve) => manager.once('exit', resolve)), new Promise((resolve) => setTimeout(resolve, 1500))]);
    }
    try { nativeProxy.restorePortableProxySettings(state); } catch (e) { error ||= e; }
    try { await nativeProxy.closeNativeProxy(state); } catch (e) { error ||= e; }
    if (existing15721?.listening) await new Promise((resolve) => existing15721.close(resolve));
  }
  if (error) throw error;
}
async function main() {
  if (process.platform !== 'linux' || process.arch !== 'x64') throw new Error('This integration requires Linux x86_64.');
  const cliArgs = process.argv.slice(2), gui = cliArgs.includes('--gui'), rootArg = cliArgs.find((arg) => arg !== '--gui');
  const root = path.resolve(rootArg || path.join(__dirname, '..'));
  const status = runtimeApi.status(root);
  if (!status.ready) {
    if (rootArg) throw new Error(`Explicit portable runtime root is incomplete: ${(status.missing || []).join(', ')}`);
    console.log(`SKIP: official portable Linux runtime unavailable: ${(status.missing || []).join(', ')}`);
    return;
  }
  if (gui && !process.env.DISPLAY) throw new Error('--gui requires an existing private X display (for example an isolated Xvfb display).');
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'portable-ai-integration-'));
  fs.chmodSync(parent, 0o700);
  const sessionRoot = path.join(parent, 'session'); fs.mkdirSync(sessionRoot, { mode: 0o700 });
  const workDir = path.join(parent, 'workspace'); fs.mkdirSync(workDir, { mode: 0o700 });
  let server;
  try {
    const runtime = runtimeApi.stageRuntime(root, sessionRoot);
    await testPythonEnvironment(root, parent);
    const version = await runOwned(sandboxApi.buildSandbox({ sessionRoot, runtime, mode: 'claude', command: runtime.claude, args: ['--version'], workDir, network: false }), 30000);
    assert.equal(version.code, 0, `bundled Claude --version failed: ${version.stderr}`);
    assert.match(version.stdout, /\d+\.\d+\.\d+/);

    // A synthetic, one-request Messages endpoint validates the real packaged
    // Claude CLI consumes the injected provider without exposing its token.
    let calls = 0, observedAuth = null, observedPath = null, rejection = null;
    server = http.createServer((req, res) => {
      calls++; server.requests = calls;
      if (calls > 8) { req.resume(); res.writeHead(429).end(); return; }
      if (/\/gateway\/v1\/messages(?:\?|$)/.test(req.url || '')) {
        observedPath = req.url;
        observedAuth = req.headers['x-api-key'] || /^Bearer\s+(.+)$/i.exec(req.headers.authorization || '')?.[1] || null;
        server.observedAuth = observedAuth;
      }
      let body = ''; req.setEncoding('utf8'); req.on('data', (chunk) => { body += chunk; if (body.length > 1024 * 1024) req.destroy(); });
      req.on('end', () => {
        let request;
        try { request = JSON.parse(body); } catch { rejection = 'request body was not JSON'; res.writeHead(400).end(); return; }
        if (!/\/gateway\/v1\/messages(?:\?|$)/.test(req.url || '') || typeof request.model !== 'string' || !Array.isArray(request.messages)) { rejection = `unexpected path/schema (${req.url}, model=${typeof request.model})`; res.writeHead(400).end(); return; }
        res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'close' });
        const events = [
          ['message_start', { type: 'message_start', message: { id: 'msg_synthetic', type: 'message', role: 'assistant', content: [], model: request.model, stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 0 } } }],
          ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
          ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'synthetic-ok' } }],
          ['content_block_stop', { type: 'content_block_stop', index: 0 }],
          ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 2 } }],
          ['message_stop', { type: 'message_stop' }],
        ];
        for (const [event, data] of events) res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
        res.end();
      });
    });
    const port = await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', () => resolve(server.address().port)); });
    const launched = await runOwned(sandboxApi.buildSandbox({
      sessionRoot, runtime, mode: 'claude', command: runtime.claude,
      args: ['--print', '--output-format', 'text', '--model', 'sonnet', 'Reply with exactly synthetic-ok.'],
      workDir, network: true,
      extraEnv: { ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}/gateway`, ANTHROPIC_AUTH_TOKEN: 'synthetic-integration-token-only', ANTHROPIC_MODEL: 'sonnet' },
    }));
    assert.equal(launched.code, 0, `bundled Claude synthetic request failed (signal ${launched.signal}; stub=${rejection || 'accepted'}): ${launched.stderr || launched.stdout}`);
    assert.ok(calls >= 1 && calls <= 8, 'real Claude CLI should issue a bounded number of requests only to the loopback test listener');
    assert.match(observedPath || '', /^\/gateway\/v1\/messages(?:\?|$)/, 'real provider prefix must survive without duplicating /v1');
    assert.equal(observedAuth, 'synthetic-integration-token-only', 'synthetic token should reach only the local test endpoint');
    assert.match(launched.stdout, /synthetic-ok/);
    console.log(`Bundled Claude ${version.stdout.trim()} passed --version and ${calls} bounded local synthetic Messages request(s).`);
    if (gui) await runGuiProxyIntegration(runtime, sessionRoot, workDir, port, server);
  } finally {
    if (server?.listening) await new Promise((resolve) => server.close(resolve));
    fs.rmSync(parent, { recursive: true, force: true });
  }
}
main().catch((e) => { console.error(e.message); process.exitCode = 1; });
