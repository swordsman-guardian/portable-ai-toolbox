'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const store = require('./linux-encrypted-store.cjs');
const ui = require('./linux-session.cjs');
const nativeProxy = require('./linux-native-proxy.cjs');
const testSessions = new Set();
const createPrivateSession = ui.createPrivateSession.bind(ui);
ui.createPrivateSession = async (...args) => { const record = await createPrivateSession(...args); testSessions.add(record); return record; };

async function run() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-linux-store-test-'));
  const password = 'synthetic-test-password';
  try {
    if (process.platform === 'linux' && fs.existsSync('/dev/shm')) assert.equal(typeof ui.mountedNoExec('/dev/shm'), 'boolean', 'project mount option detection should resolve explicitly');
    const boundaryRoot = fs.mkdtempSync(path.join('/var/tmp', 'ai-linux-boundary-usb-'));
    const allowedWork = path.join(boundaryRoot, 'project'); fs.mkdirSync(allowedWork);
    assert.equal(ui.validateWorkDirectory(boundaryRoot, allowedWork), fs.realpathSync(allowedWork));
    const syntheticFatMount = `501 1 8:1 / ${allowedWork.replace(/ /g, '\\040')} rw,nosuid,nodev,noexec - vfat /dev/synthetic rw`;
    const fatPython = ui.pythonEnvironmentLayout(boundaryRoot, allowedWork, syntheticFatMount);
    assert.equal(fatPython.privateEnvironment, true, 'FAT32/noexec projects must use the private host environment');
    assert.ok(fatPython.venv.startsWith(path.join(os.tmpdir(), `portable-ai-${process.getuid()}`, 'python-projects')));
    const syntheticLinuxMount = `502 1 8:2 / ${allowedWork.replace(/ /g, '\\040')} rw - ext4 /dev/synthetic rw`;
    const linuxPython = ui.pythonEnvironmentLayout(boundaryRoot, allowedWork, syntheticLinuxMount);
    assert.equal(linuxPython.privateEnvironment, false, 'native executable project filesystems may keep project-local venvs');
    assert.equal(linuxPython.venv, path.join(allowedWork, '.venv'));
    for (const forbidden of [boundaryRoot, '/var', '/', os.homedir(), path.dirname(os.homedir()), path.dirname(path.dirname(os.homedir())), '/tmp', path.join(os.tmpdir(), `portable-ai-${process.getuid()}`)]) {
      assert.throws(() => ui.validateWorkDirectory(boundaryRoot, forbidden), /工作目录/);
    }
    const reservedConfig = path.join(boundaryRoot, 'config', 'cc-switch'); fs.mkdirSync(reservedConfig, { recursive: true });
    assert.throws(() => ui.validateWorkDirectory(boundaryRoot, reservedConfig), /config/);
    const nestedHomeProject = path.join(os.homedir(), `portable-ai-test-${process.pid}`); fs.mkdirSync(nestedHomeProject, { recursive: true });
    assert.equal(ui.validateWorkDirectory(boundaryRoot, nestedHomeProject), fs.realpathSync(nestedHomeProject));
    fs.rmSync(nestedHomeProject, { recursive: true, force: true });
    fs.rmSync(boundaryRoot, { recursive: true, force: true });
    let opened = store.openStore(root, password, { create: true });
    store.saveSnapshot(opened, new Map([['harness/cc-switch/claude/settings.json', Buffer.from('{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid"}}')]]));
    opened.close();
    if (process.platform === 'linux' && fs.existsSync('/usr/bin/script')) await testFirstLaunchPty();

    const restoreLifecycle = await ui.createPrivateSession(root, 'claude');
    restoreLifecycle.opened = store.openStore(root, password);
    assert.equal(fs.existsSync(path.join(restoreLifecycle.dir, '.portable-session.json')), false, 'empty private session must not block canonical snapshot restore');
    store.restoreSnapshot(store.readSnapshot(restoreLifecycle.opened), restoreLifecycle.dir);
    ui.writePrivateOwner(restoreLifecycle);
    assert.equal(fs.existsSync(path.join(restoreLifecycle.dir, '.portable-session.json')), true, 'crash metadata is written after snapshot restore');
    await Promise.all([ui.saveAndRemove(restoreLifecycle), ui.saveAndRemove(restoreLifecycle)]);
    assert.equal(ui.sessionCount(), 0, 'completed cleanup must remove the session from the process-owned session map');

    const a = await ui.createPrivateSession(root); a.opened = store.openStore(root, password);
    const b = await ui.createPrivateSession(root); b.opened = store.openStore(root, password);
    assert.notEqual(a.dir, b.dir, 'separate windows must have separate private configuration trees');
    store.restoreSnapshot(store.readSnapshot(a.opened), a.dir);
    store.restoreSnapshot(store.readSnapshot(b.opened), b.dir);
    const bp = path.join(b.dir, 'harness', 'cc-switch', 'claude', 'settings.json');
    fs.writeFileSync(path.join(a.dir, 'harness', 'cc-switch', 'claude', 'settings.json'), '{"name":"window-a"}');
    fs.writeFileSync(bp, '{"name":"window-b"}');
    await ui.saveAndRemove(a);
    await ui.saveAndRemove(b);
    opened = store.openStore(root, password);
    const final = store.readSnapshot(opened);
    assert.equal(final.get('harness/cc-switch/claude/settings.json').toString(), '{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid"}}', 'Claude session close must not overwrite shared CC Switch/provider settings');
    assert.equal(store.storeStatus(root).state, 'Locked');
    opened.close();
    const lease = ui.acquireWriterLease(root);
    assert.throws(() => ui.acquireWriterLease(root), /另一个工具箱窗口/);
    ui.releaseWriterLease(lease);
    const reopened = ui.acquireWriterLease(root); ui.releaseWriterLease(reopened);

    const firstRun = await ui.createPrivateSession(root, 'cc-switch');
    firstRun.opened = store.openStore(root, password);
    firstRun.originalSnapshot = store.readSnapshot(firstRun.opened);
    ui.localizeCcSwitchSettings(firstRun.dir);
    const firstSettings = JSON.parse(fs.readFileSync(path.join(firstRun.dir, 'config', 'cc-switch', 'home', '.cc-switch', 'settings.json'), 'utf8'));
    assert.equal(firstSettings.claudeConfigDir, '/config/claude', 'first-run settings must direct Claude data into its archived config tree');
    assert.equal(firstSettings.codexConfigDir, '/harness/cc-switch/codex');
    firstSettings.claudeConfigDir = '/config/claude'; firstSettings.codexConfigDir = '/harness/cc-switch/codex';
    ui.restorePortablePathSettings({}, firstSettings);
    assert.equal(Object.hasOwn(firstSettings, 'claudeConfigDir'), false, 'sandbox absolute paths must not leak into portable snapshots');
    await ui.saveAndRemove(firstRun);
    const firstRunSaved = store.openStore(root, password); const savedSettings = store.readSnapshot(firstRunSaved).get('config/cc-switch/home/.cc-switch/settings.json');
    assert.equal(Object.hasOwn(JSON.parse(savedSettings.toString()), 'claudeConfigDir'), false);
    firstRunSaved.close();
    const secretSettings = path.join(firstRun.dir, 'harness', 'cc-switch', 'claude', 'settings.json');
    fs.mkdirSync(path.dirname(secretSettings), { recursive: true });
    fs.writeFileSync(secretSettings, JSON.stringify({ env: { ANTHROPIC_AUTH_TOKEN: 'stale-auth', ANTHROPIC_API_KEY: 'stale-api-key', ANTHROPIC_BASE_URL: 'http://127.0.0.1:15721', ANTHROPIC_MODEL: 'stale-model', ANTHROPIC_REASONING_MODEL: 'stale-reasoning-model', KEEP_ME: 'yes' } }));
    ui.scrubClaudeSettings(path.dirname(secretSettings));
    const cleanEnv = JSON.parse(fs.readFileSync(secretSettings, 'utf8')).env;
    for (const key of ['ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_MODEL', 'ANTHROPIC_REASONING_MODEL']) assert.equal(Object.hasOwn(cleanEnv, key), false);
    assert.equal(cleanEnv.KEEP_ME, 'yes');
    fs.rmSync(secretSettings, { force: true });

    const historyRecord = await ui.createPrivateSession(root, 'claude');
    historyRecord.opened = store.openStore(root, password);
    historyRecord.workHash = 'a'.repeat(64);
    historyRecord.claudeConfigDir = path.join(historyRecord.dir, 'harness', 'cc-switch', 'claude');
    const transcript = path.join(historyRecord.claudeConfigDir, 'projects', 'synthetic.jsonl');
    fs.mkdirSync(path.dirname(transcript), { recursive: true });
    fs.writeFileSync(transcript, '{"role":"user","content":"synthetic-history-only"}\n');
    await ui.saveAndRemove(historyRecord);
    const archiveDir = path.join(root, 'sessions', 'linux', 'claude', historyRecord.workHash);
    const archiveFile = path.join(archiveDir, `${historyRecord.id}.enc`);
    assert.ok(fs.existsSync(archiveFile), 'Claude history must be written as an encrypted per-project archive');
    const archiveBytes = fs.readFileSync(archiveFile);
    assert.equal(archiveBytes.includes(Buffer.from('synthetic-history-only')), false, 'USB archive must not contain transcript plaintext');
    const historySession = store.openStore(root, password);
    const historyPayload = store.openArchive(historySession, archiveBytes, { kind: 'claude-session-archive' });
    const decodedHistory = ui.validateHistoryPayload(historyPayload, historyRecord.workHash);
    assert.equal(decodedHistory.get('projects/synthetic.jsonl').toString(), '{"role":"user","content":"synthetic-history-only"}\n');
    historySession.close();

    const concurrent = await Promise.all([ui.createPrivateSession(root, 'claude'), ui.createPrivateSession(root, 'claude')]);
    for (const [index, record] of concurrent.entries()) {
      record.opened = store.openStore(root, password); record.workHash = historyRecord.workHash;
      record.claudeConfigDir = path.join(record.dir, 'harness', 'cc-switch', 'claude');
      const file = path.join(record.claudeConfigDir, 'projects', `parallel-${index}.jsonl`);
      fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `parallel-run-${index}`);
    }
    await Promise.all(concurrent.map((record) => ui.saveAndRemove(record)));
    const mergedSession = store.openStore(root, password);
    const mergedHistory = ui.latestClaudeHistory(root, historyRecord.workHash, mergedSession);
    assert.equal(mergedHistory.get('projects/parallel-0.jsonl').toString(), 'parallel-run-0');
    assert.equal(mergedHistory.get('projects/parallel-1.jsonl').toString(), 'parallel-run-1');
    if (process.platform === 'linux') {
      const hostileArchive = path.join(archiveDir, 'hostile-link.enc');
      fs.symlinkSync('/dev/zero', hostileArchive);
      assert.throws(() => ui.latestClaudeHistory(root, historyRecord.workHash, mergedSession), /symbolic link|regular file|Claude history archive/i,
        'history restore must reject a USB archive symlink before reading its target');
      fs.unlinkSync(hostileArchive);
    }
    const restoredDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-linux-history-restore-'));
    ui.restoreLatestClaudeHistory(root, { workHash: historyRecord.workHash, opened: mergedSession }, restoredDir);
    assert.equal(fs.readFileSync(path.join(restoredDir, 'projects', 'parallel-0.jsonl'), 'utf8'), 'parallel-run-0');
    assert.equal(fs.readFileSync(path.join(restoredDir, 'projects', 'parallel-1.jsonl'), 'utf8'), 'parallel-run-1');
    fs.rmSync(restoredDir, { recursive: true, force: true });
    mergedSession.close();

    const brokerRecord = await ui.createPrivateSession(root, 'cc-switch');
    brokerRecord.opened = store.openStore(root, password);
    const liveSettings = path.join(brokerRecord.dir, 'harness', 'cc-switch', 'claude', 'settings.json');
    fs.mkdirSync(path.dirname(liveSettings), { recursive: true });
    fs.writeFileSync(liveSettings, JSON.stringify({ name: 'synthetic-current', env: { ANTHROPIC_BASE_URL: 'https://example.invalid/v1', ANTHROPIC_AUTH_TOKEN: 'synthetic-broker-secret', ANTHROPIC_MODEL: 'synthetic-model' } }));
    brokerRecord.broker = await ui.startProviderBroker(root, brokerRecord);
    const liveProvider = await ui.getLiveProvider(root);
    assert.equal(liveProvider.name, 'synthetic-current');
    assert.equal(liveProvider.secret, 'synthetic-broker-secret');
    const unauthorized = await new Promise((resolve, reject) => {
      const socket = net.createConnection(brokerRecord.broker.socket); let data = '';
      socket.once('connect', () => socket.write('{"token":"wrong-token","action":"lock"}\n'));
      socket.on('data', (chunk) => { data += chunk.toString(); if (data.includes('\n')) { socket.end(); resolve(JSON.parse(data.slice(0, data.indexOf('\n')))); } });
      socket.once('error', reject);
    });
    assert.equal(unauthorized.error, 'unauthorized');
    assert.equal(brokerRecord.closed, false, 'unauthenticated broker lock must not stop a manager session');
    ui.stopProviderBroker(brokerRecord.broker); brokerRecord.broker = null;
    await ui.saveAndRemove(brokerRecord);

    const lockRecord = await ui.createPrivateSession(root, 'cc-switch');
    lockRecord.opened = store.openStore(root, password); lockRecord.writerLease = ui.acquireWriterLease(root);
    lockRecord.originalSnapshot = store.readSnapshot(lockRecord.opened); store.restoreSnapshot(lockRecord.originalSnapshot, lockRecord.dir);
    const activeManager = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { detached: true, stdio: 'ignore' });
    await once(activeManager, 'spawn'); lockRecord.managerChild = activeManager; lockRecord.children.add(activeManager); ui.writePrivateOwner(lockRecord);
    lockRecord.broker = await ui.startProviderBroker(root, lockRecord);
    const unrelatedManager = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { detached: true, stdio: 'ignore' });
    await once(unrelatedManager, 'spawn');
    assert.equal(await ui.lockActiveManager(root), true, 'authenticated lock request should wait for this USB manager cleanup');
    assert.ok(activeManager.exitCode !== null || activeManager.signalCode !== null, 'lock request should stop the exact owned CC Switch process group');
    assert.equal(unrelatedManager.exitCode, null, 'lock request must not stop an unrelated manager process');
    assert.equal(unrelatedManager.signalCode, null, 'lock request must not signal an unrelated manager process');
    unrelatedManager.kill('SIGTERM'); await once(unrelatedManager, 'exit');

    // Exercise the real request builder against a local synthetic server. The
    // provider's gateway prefix must survive, and /v1 must appear exactly once.
    const stub = net.createServer((socket) => {
      let request = '';
      socket.on('data', (chunk) => {
        request += chunk.toString('utf8');
        if (request.includes('\r\n\r\n')) {
          const requestLine = request.split('\r\n', 1)[0];
          socket.end('HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
          stub.lastRequestLine = requestLine;
        }
      });
    });
    await new Promise((resolve, reject) => { stub.once('error', reject); stub.listen(0, '127.0.0.1', resolve); });
    try {
      const base = `http://127.0.0.1:${stub.address().port}`;
      await ui.testProvider({ mode: 'managed-native-proxy', baseUrl: `${base}/gateway/v1/`, secret: 'synthetic-only', authEnvironmentName: 'ANTHROPIC_AUTH_TOKEN', models: { ANTHROPIC_MODEL: 'synthetic-model' } });
      assert.equal(stub.lastRequestLine, 'POST /gateway/v1/messages HTTP/1.1');
      await ui.testProvider({ mode: 'managed-native-proxy', baseUrl: `${base}/gateway`, secret: 'synthetic-only', authEnvironmentName: 'ANTHROPIC_AUTH_TOKEN', models: {} });
      assert.equal(stub.lastRequestLine, 'POST /gateway/v1/messages HTTP/1.1');
    } finally { await new Promise((resolve) => stub.close(resolve)); }

    if (process.platform === 'linux') {
      let fixed = null;
      try { fixed = net.createServer(); await new Promise((resolve, reject) => { fixed.once('error', reject); fixed.listen(15721, '127.0.0.1', resolve); }); }
      catch { if (fixed) fixed.close(); fixed = null; }
      const proxyRecord = await ui.createPrivateSession(root, 'cc-switch');
      proxyRecord.opened = store.openStore(root, password); proxyRecord.originalSnapshot = store.readSnapshot(proxyRecord.opened);
      const proxySettings = path.join(proxyRecord.dir, 'harness', 'cc-switch', 'claude', 'settings.json');
      fs.mkdirSync(path.dirname(proxySettings), { recursive: true });
      fs.writeFileSync(proxySettings, JSON.stringify({ env: { ANTHROPIC_BASE_URL: 'http://127.0.0.1:15721', ANTHROPIC_AUTH_TOKEN: 'PROXY_MANAGED' } }));
      const state = await nativeProxy.prepareNativeProxy({ sessionRoot: proxyRecord.dir, network: true });
      assert.notEqual(state.port, 15721, 'per-session native proxy must not collide with the conventional host listener');
      if (fixed) await new Promise((resolve) => fixed.close(resolve));
      const { DatabaseSync } = require('node:sqlite');
      const db = new DatabaseSync(state.dbPath);
      try { db.prepare("UPDATE proxy_config SET proxy_enabled=1 WHERE app_type='claude'").run(); } finally { db.close(); }
      proxyRecord.nativeProxy = state;
      await nativeProxy.releaseReservation(state);
      const manager = spawn(process.execPath, ['-e', `require('node:net').createServer().listen(${state.port}, '127.0.0.1')`], { detached: true, stdio: 'ignore' });
      await new Promise((resolve, reject) => { manager.once('spawn', resolve); manager.once('error', reject); });
      proxyRecord.managerChild = manager; proxyRecord.children.add(manager); nativeProxy.attachManager(state, manager.pid);
      proxyRecord.broker = await ui.startProviderBroker(root, proxyRecord);
      let liveNative = null;
      for (let i = 0; i < 30; i++) { try { liveNative = await ui.getLiveProvider(root); if (liveNative?.mode === 'managed-native-proxy') break; } catch {} await new Promise((resolve) => setTimeout(resolve, 100)); }
      assert.equal(liveNative?.mode, 'managed-native-proxy', 'broker must expose only the proxy listener owned by this CC Switch manager');
      assert.equal(new URL(liveNative.baseUrl).port, String(state.port));
      ui.stopProviderBroker(proxyRecord.broker); proxyRecord.broker = null;
      await ui.saveAndRemove(proxyRecord);
    }

    const ccUnplug = await ui.createPrivateSession(root, 'cc-switch');
    ccUnplug.opened = store.openStore(root, password);
    const ccSyntheticSettings = path.join(ccUnplug.dir, 'config', 'cc-switch', 'home', '.cc-switch', 'settings.json');
    fs.mkdirSync(path.dirname(ccSyntheticSettings), { recursive: true, mode: 0o700 });
    fs.writeFileSync(ccSyntheticSettings, JSON.stringify({ synthetic: true }), { mode: 0o600 });
    const ccChild = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { detached: true, stdio: 'ignore' });
    await new Promise((resolve, reject) => { ccChild.once('spawn', resolve); ccChild.once('error', reject); });
    ccUnplug.managerChild = ccChild; ccUnplug.children.add(ccChild);
    ui.watchForUnplug(ccUnplug, 'CC Switch');
    ccUnplug.identity.mountId = 'synthetic-cc-remount-change';
    const unplugDeadline = Date.now() + 6000;
    while (!ccUnplug.cleaned && Date.now() < unplugDeadline) await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(ccUnplug.cleaned, true, 'CC Switch unplug watcher must stop its owned GUI and encrypt/remove its private session');
    assert.equal(ccChild.exitCode !== null || ccChild.signalCode !== null, true, 'CC Switch unplug cleanup must wait for the owned process to stop');
    const ccRecoveryDir = path.join(os.tmpdir(), `portable-ai-${process.getuid ? process.getuid() : 'user'}`, 'recovery');
    const ccRecovery = path.join(ccRecoveryDir, `${ccUnplug.id}.recovery.json`);
    assert.ok(fs.existsSync(ccRecovery), 'CC Switch unplug must retain an encrypted local recovery bundle');
    await ui.restorePrivateBundle(root, ccRecovery, password);

    const hupState = path.join(root, 'hup-state.json');
    const modulePath = path.resolve(__dirname, 'linux-session.cjs');
    const storePath = path.resolve(__dirname, 'linux-encrypted-store.cjs');
    const hupScript = `const fs=require('node:fs'),path=require('node:path'),{spawn}=require('node:child_process'),ui=require(${JSON.stringify(modulePath)}),store=require(${JSON.stringify(storePath)});(async()=>{const root=process.argv[1],password=process.argv[2],state=process.argv[3],r=await ui.createPrivateSession(root,'claude');r.opened=store.openStore(root,password);r.workHash='${'e'.repeat(64)}';r.claudeConfigDir=path.join(r.dir,'harness','cc-switch','claude');const f=path.join(r.claudeConfigDir,'projects','hup.jsonl');fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,'hup-cleanup-sentinel');const c=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'});await new Promise((ok,bad)=>{c.once('spawn',ok);c.once('error',bad)});r.children.add(c);r.managerChild=c;fs.writeFileSync(state,JSON.stringify({dir:r.dir,pid:c.pid}));ui.installExitHandlers();setTimeout(()=>process.kill(process.pid,'SIGHUP'),100)})().catch(e=>{console.error(e);process.exit(2)})`;
    const hupWorker = spawn(process.execPath, ['-e', hupScript, root, password, hupState], { stdio: 'ignore' });
    let hupTimer;
    const hupExit = await Promise.race([
      once(hupWorker, 'exit'),
      new Promise((_, reject) => { hupTimer = setTimeout(() => reject(new Error('synthetic SIGHUP cleanup worker timed out')), 12000); }),
    ]);
    clearTimeout(hupTimer);
    assert.equal(hupExit[0], 129, 'SIGHUP must await owned cleanup before exiting with its conventional status');
    const hup = JSON.parse(fs.readFileSync(hupState, 'utf8'));
    assert.equal(fs.existsSync(hup.dir), false, 'SIGHUP cleanup must remove the private plaintext session after archive');
    assert.throws(() => process.kill(hup.pid, 0), (error) => error.code === 'ESRCH', 'SIGHUP cleanup must stop the owned process group');

    const unplugged = await ui.createPrivateSession(root, 'claude');
    unplugged.opened = store.openStore(root, password); unplugged.workHash = 'b'.repeat(64);
    unplugged.claudeConfigDir = path.join(unplugged.dir, 'harness', 'cc-switch', 'claude');
    const recoveryTranscript = path.join(unplugged.claudeConfigDir, 'projects', 'unplug.jsonl');
    fs.mkdirSync(path.dirname(recoveryTranscript), { recursive: true }); fs.writeFileSync(recoveryTranscript, 'recovery-transcript-sentinel');
    unplugged.identity.mountId = 'synthetic-remount-change';
    await ui.saveAndRemove(unplugged);
    assert.equal(fs.existsSync(unplugged.dir), false, 'successful encrypted unplug recovery must remove the plaintext session tree');
    const recoveryDir = path.join(os.tmpdir(), `portable-ai-${process.getuid ? process.getuid() : 'user'}`, 'recovery');
    const bundlePath = path.join(recoveryDir, `${unplugged.id}.recovery.json`);
    assert.ok(fs.existsSync(bundlePath), 'unplug recovery must retain a local encrypted recovery bundle');
    const recoveryBundle = JSON.parse(fs.readFileSync(bundlePath, 'utf8'));
    assert.equal(Buffer.from(recoveryBundle.archive, 'base64').includes(Buffer.from('recovery-transcript-sentinel')), false);
    await assert.rejects(ui.restorePrivateBundle(root, bundlePath, 'wrong-synthetic-password'), /恢复密码不正确/);
    assert.ok(fs.existsSync(bundlePath), 'a failed unlock must preserve the only encrypted recovery copy');
    await ui.restorePrivateBundle(root, bundlePath, password);
    const restoredArchive = path.join(root, 'sessions', 'linux', 'claude', 'b'.repeat(64), `${unplugged.id}.enc`);
    assert.ok(fs.existsSync(restoredArchive), 'recovery import must return the encrypted session to the reconnected USB');
    const restoredSession = store.openStore(root, password);
    const restoredPayload = store.openArchive(restoredSession, fs.readFileSync(restoredArchive), { kind: 'claude-session-archive' });
    assert.equal(ui.validateHistoryPayload(restoredPayload, 'b'.repeat(64)).get('projects/unplug.jsonl').toString(), 'recovery-transcript-sentinel');
    restoredSession.close();
    assert.equal(fs.existsSync(bundlePath), false, 'successfully imported recovery should be removed from the local queue');

    const orphan = await ui.createPrivateSession(root, 'claude'); orphan.opened = store.openStore(root, password);
    orphan.workHash = 'c'.repeat(64); orphan.claudeConfigDir = path.join(orphan.dir, 'harness', 'cc-switch', 'claude');
    const orphanJsonl = path.join(orphan.claudeConfigDir, 'projects', 'orphan.jsonl');
    fs.mkdirSync(path.dirname(orphanJsonl), { recursive: true }); fs.writeFileSync(orphanJsonl, 'orphan-crash-history');
    ui.writePrivateOwner(orphan);
    const ownerFile = path.join(orphan.dir, '.portable-session.json');
    const orphanMetadata = JSON.parse(fs.readFileSync(ownerFile, 'utf8'));
    orphanMetadata.owner = { pid: 2147483647, bootId: ui.usbIdentity(root).mountId || 'dead-boot-id', start: '1' };
    fs.writeFileSync(ownerFile, JSON.stringify(orphanMetadata), { mode: 0o600 });
    const orphanRecovery = await ui.recoverOrphanSession(root, orphan.dir, password);
    assert.equal(fs.existsSync(orphan.dir), false, 'verified crash-orphan recovery must remove the plaintext private tree');
    assert.ok(fs.existsSync(orphanRecovery));
    const orphanBundle = JSON.parse(fs.readFileSync(orphanRecovery, 'utf8'));
    assert.equal(Buffer.from(orphanBundle.archive, 'base64').includes(Buffer.from('orphan-crash-history')), false);
    await ui.restorePrivateBundle(root, orphanRecovery, password);
    const orphanArchive = path.join(root, 'sessions', 'linux', 'claude', orphan.workHash, `${orphan.id}.enc`);
    const orphanSession = store.openStore(root, password);
    assert.equal(ui.validateHistoryPayload(store.openArchive(orphanSession, fs.readFileSync(orphanArchive), { kind: 'claude-session-archive' }), orphan.workHash).get('projects/orphan.jsonl').toString(), 'orphan-crash-history');
    orphanSession.close();
    assert.equal(ui.sessionCount(), 0, 'orphan recovery and every normal close must release in-memory session records');
    console.log('Linux encrypted multi-session lifecycle checks passed.');
  } finally {
    for (const record of testSessions) {
      try { await ui.saveAndRemove(record); } catch {}
      const expectedBase = path.join(os.tmpdir(), `portable-ai-${process.getuid ? process.getuid() : 'user'}`);
      if (record.root === root && path.dirname(record.dir) === expectedBase && fs.existsSync(record.dir)) {
        // These records were created by this synthetic suite against its fresh
        // encrypted fixture. Never sweep the shared private base.
        fs.rmSync(record.dir, { recursive: true, force: true });
      }
    }
    fs.rmSync(root, { recursive: true, force: true });
  }
}

async function testFirstLaunchPty() {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-linux-pty-first-run-'));
  const scripts = path.join(fixture, 'scripts'), project = path.join(fixture, 'project'), tmp = path.join(fixture, 'tmp');
  fs.mkdirSync(scripts, { mode: 0o700 }); fs.mkdirSync(project, { mode: 0o700 }); fs.mkdirSync(tmp, { mode: 0o700 });
  for (const name of ['ai.cjs', 'linux-session.cjs', 'linux-encrypted-store.cjs', 'linux-runtime.cjs', 'linux-sandbox.cjs', 'linux-native-proxy.cjs']) {
    fs.copyFileSync(path.join(__dirname, name), path.join(scripts, name));
  }
  const quote = (s) => `'${s.replace(/'/g, `'\\''`)}'`;
  const child = spawn('/usr/bin/script', ['-qec', `${quote(process.execPath)} ${quote(path.join(scripts, 'ai.cjs'))} --settings`, '/dev/null'], {
    cwd: project, env: { PATH: '/usr/bin:/bin', HOME: fixture, TMPDIR: tmp, TERM: 'xterm', LANG: 'C.UTF-8' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', (b) => { output += b.toString(); });
  child.stderr.on('data', (b) => { output += b.toString(); });
  const waitFor = async (text) => {
    const deadline = Date.now() + 8000;
    while (!output.includes(text)) {
      if (child.exitCode !== null) throw new Error(`PTY first-run CLI exited before prompt: ${output}`);
      if (Date.now() > deadline) throw new Error(`PTY first-run CLI did not show ${text}: ${output}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };
  try {
    await waitFor('请选择：'); child.stdin.write('6\n');
    await waitFor('设置主密码: '); child.stdin.write('synthetic-pty-password\n');
    await waitFor('再次输入主密码: '); child.stdin.write('synthetic-pty-password\n');
    await waitFor('portable Linux runtime is incomplete');
    await waitFor('请选择：'); child.stdin.write('0\n');
    const [code] = await Promise.race([once(child, 'exit'), new Promise((_, reject) => setTimeout(() => reject(new Error('PTY first-run CLI did not exit')), 8000))]);
    assert.equal(code, 0, `first-run CLI failed: ${output}`);
    assert.equal(output.includes('synthetic-pty-password'), false, 'masked master password must never appear in terminal output');
    assert.equal(store.storeStatus(fixture).state, 'Locked', 'PTY first-run settings must create a recoverable encrypted vault despite missing assets');
    console.log('Synthetic TTY first-run password and private vault creation passed.');
  } finally {
    if (child.exitCode === null) { child.kill('SIGTERM'); await Promise.race([once(child, 'exit'), new Promise((resolve) => setTimeout(resolve, 1000))]); }
    fs.rmSync(fixture, { recursive: true, force: true });
  }
}

run().catch((e) => { console.error(e); process.exitCode = 1; });
