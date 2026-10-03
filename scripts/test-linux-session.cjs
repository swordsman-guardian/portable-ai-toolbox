'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { EventEmitter } = require('node:events');
const store = require('./linux-encrypted-store.cjs');
const ui = require('./linux-session.cjs');
const nativeProxy = require('./linux-native-proxy.cjs');
const runtimeApi = require('./linux-runtime.cjs');
let usernsApi = null; try { usernsApi = require('./linux-userns.cjs'); } catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e; }
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

    if (process.platform === 'linux' && usernsApi) {
      const oldStage = runtimeApi.stageRuntime, oldEnsure = usernsApi.ensureSandboxUserns, oldRelease = usernsApi.releaseSandboxUserns;
      const released = [];
      runtimeApi.stageRuntime = async (_root, sessionRoot) => ({ sessionRoot, bwrap: '/synthetic/bwrap' });
      usernsApi.ensureSandboxUserns = async (runtime) => { assert.equal(runtime.bwrap, '/synthetic/bwrap'); return { fixed: true, authorization: { synthetic: `auth-${released.length}` } }; };
      usernsApi.releaseSandboxUserns = async (authorization) => { released.push(authorization); };
      try {
        const revisionBefore = store.storeStatus(root).currentRevision;
        await assert.rejects(ui.runCcSwitch(root, false), /TTY|password/i, 'synthetic noninteractive unlock should refuse after the capability grant');
        assert.equal(store.storeStatus(root).currentRevision, revisionBefore, 'prelaunch refusal must leave the encrypted revision untouched');
        assert.equal(ui.sessionCount(), 0, 'prelaunch refusal must release its session record');
        await assert.rejects(ui.runCcSwitch(root, false), /TTY|password/i, 'the same menu process should be able to reacquire after refusal cleanup');
        assert.equal(released.length, 2, 'each prelaunch failure must release its ephemeral AppArmor authorization');
        assert.equal(store.storeStatus(root).currentRevision, revisionBefore);
      } finally {
        runtimeApi.stageRuntime = oldStage; usernsApi.ensureSandboxUserns = oldEnsure; usernsApi.releaseSandboxUserns = oldRelease;
      }

      const stopped = await ui.createPrivateSession(root, 'cc-switch'); stopped.discard = true;
      const owned = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { detached: true, stdio: 'ignore' });
      await once(owned, 'spawn'); stopped.children.add(owned);
      let brokerCloseCount = 0, releaseOnStopFailure = 0;
      const stopBroker = { server: { close() { brokerCloseCount++; } }, socket: path.join(stopped.dir, 'missing.sock'), locator: path.join(stopped.dir, 'missing.json') };
      const stopAuthorization = { synthetic: 'stop-error' };
      stopped.broker = stopBroker; stopped.usernsAuthorization = stopAuthorization;
      const oldReleaseForStop = usernsApi.releaseSandboxUserns, oldKill = process.kill;
      usernsApi.releaseSandboxUserns = async () => { releaseOnStopFailure++; };
      process.kill = (pid, signal) => {
        if (pid === -owned.pid && signal === 'SIGTERM') { const error = new Error('synthetic owned-process stop failure'); error.code = 'EPERM'; throw error; }
        return oldKill(pid, signal);
      };
      try { await ui.saveAndRemove(stopped); }
      finally { process.kill = oldKill; usernsApi.releaseSandboxUserns = oldReleaseForStop; }
      assert.equal(stopped.closed, false, 'failed process shutdown leaves cleanup retryable');
      assert.equal(stopped.broker, stopBroker, 'failed process shutdown must retain the provider broker');
      assert.equal(brokerCloseCount, 0, 'failed process shutdown must not close the broker');
      assert.equal(stopped.usernsAuthorization, stopAuthorization, 'failed process shutdown must retain the AppArmor authorization');
      assert.equal(releaseOnStopFailure, 0, 'failed process shutdown must not attempt policy release');
      assert.equal(fs.existsSync(stopped.dir), true, 'failed process shutdown must keep its private files');
      try { oldKill(-owned.pid, 'SIGTERM'); } catch {}
      await Promise.race([once(owned, 'exit'), new Promise((resolve) => setTimeout(resolve, 2000))]);
      stopped.children.clear(); stopped.broker = null;
      usernsApi.releaseSandboxUserns = async () => {};
      await ui.saveAndRemove(stopped);
      usernsApi.releaseSandboxUserns = oldReleaseForStop;
      assert.equal(stopped.cleaned, true, 'a later cleanup retry should remove the stopped discard session');

      const releaseFailure = await ui.createPrivateSession(root, 'cc-switch');
      releaseFailure.opened = store.openStore(root, password);
      releaseFailure.writerLease = ui.acquireWriterLease(root);
      releaseFailure.originalSnapshot = store.readSnapshot(releaseFailure.opened);
      store.restoreSnapshot(releaseFailure.originalSnapshot, releaseFailure.dir);
      releaseFailure.usernsAuthorization = { synthetic: 'unload-retry' };
      const edited = path.join(releaseFailure.dir, 'config/cc-switch/home/.cc-switch/settings.json');
      fs.mkdirSync(path.dirname(edited), { recursive: true, mode: 0o700 });
      fs.writeFileSync(edited, '{"synthetic":"preserved-until-encrypted"}', { mode: 0o600 });
      const revisionBeforeUnloadFailure = store.storeStatus(root).currentRevision;
      let unloadAttempts = 0, cleanupWarning = '';
      const oldReleaseForFailure = usernsApi.releaseSandboxUserns, oldError = console.error;
      usernsApi.releaseSandboxUserns = async () => { if (++unloadAttempts === 1) throw new Error('run: sudo apparmor_parser -K -R synthetic-profile'); };
      console.error = (message) => { cleanupWarning += `${message}\n`; };
      try { await ui.saveAndRemove(releaseFailure); }
      finally { console.error = oldError; }
      assert.equal(releaseFailure.closed, false, 'unconfirmed profile removal must leave cleanup incomplete');
      assert.equal(releaseFailure.cleaned, undefined, 'unconfirmed profile removal must not claim cleanup');
      assert.equal(releaseFailure.usernsAuthorization.synthetic, 'unload-retry', 'the authorization handle must be retained after release failure');
      assert.equal(fs.existsSync(releaseFailure.dir), true, 'release failure must retain the private session directory');
      assert.equal(fs.readFileSync(edited, 'utf8'), '{"synthetic":"preserved-until-encrypted"}', 'edited plaintext must survive a failed release until encrypted');
      assert.equal(store.storeStatus(root).currentRevision, revisionBeforeUnloadFailure, 'failed policy release must not partially commit an encrypted snapshot');
      assert.match(cleanupWarning, /sudo apparmor_parser -K -R synthetic-profile/, 'cleanup failure must expose its manual profile removal command');
      usernsApi.releaseSandboxUserns = async () => {};
      assert.equal(await ui.lockActiveManager(root), true, 'the public CC Switch lock action should retry a retained same-root cleanup before broker lookup');
      usernsApi.releaseSandboxUserns = oldReleaseForFailure;
      assert.equal(releaseFailure.cleaned, true, 'cleanup can be retried after policy removal succeeds');
      const savedAfterRetry = store.openStore(root, password);
      assert.equal(store.readSnapshot(savedAfterRetry).get('config/cc-switch/home/.cc-switch/settings.json').toString(), '{"synthetic":"preserved-until-encrypted"}',
        'retry must encrypt edits before removing their private plaintext source');
      savedAfterRetry.close();

      const oldStageAfterGateFailure = runtimeApi.stageRuntime, oldEnsureAfterGateFailure = usernsApi.ensureSandboxUserns;
      const oldReleaseAfterGateFailure = usernsApi.releaseSandboxUserns;
      runtimeApi.stageRuntime = async (_root, sessionRoot) => ({ sessionRoot, bwrap: '/synthetic/bwrap' });
      let partialAuthorization = null, partialSessionRoot = null;
      usernsApi.ensureSandboxUserns = async (runtime) => {
        const marker = path.join(runtime.sessionRoot, '.apparmor-cleanup-unconfirmed');
        fs.writeFileSync(marker, 'synthetic uncertainty', { mode: 0o600, flag: 'wx' });
        partialSessionRoot = runtime.sessionRoot;
        partialAuthorization = { profile: { name: '' }, sessionRoot: runtime.sessionRoot };
        const error = new Error('synthetic setup failed after authorization');
        error.usernsAuthorization = partialAuthorization;
        throw error;
      };
      let partialReleaseAttempts = 0;
      usernsApi.releaseSandboxUserns = async (authorization) => {
        assert.equal(authorization, partialAuthorization);
        assert.equal(authorization.profile.name, '');
        if (++partialReleaseAttempts === 1) throw new Error('synthetic partial authorization unload failure');
        fs.unlinkSync(path.join(authorization.sessionRoot, '.apparmor-cleanup-unconfirmed'));
      };
      const revisionBeforePartialGate = store.storeStatus(root).currentRevision;
      try {
        await assert.rejects(ui.runCcSwitch(root, false), /synthetic setup failed after authorization/);
        assert.ok(partialAuthorization, 'failed ensure cleanup must preserve its partial authorization handle');
        assert.ok(partialSessionRoot, 'failed ensure cleanup must retain the private profile attachment path');
        assert.equal(fs.existsSync(path.join(partialSessionRoot, '.apparmor-cleanup-unconfirmed')), true, 'uncertain helper cleanup marker must remain in the private tree');
        assert.equal(fs.existsSync(partialSessionRoot), true, 'the profile attachment path must remain private and present');
        assert.equal(store.storeStatus(root).currentRevision, revisionBeforePartialGate, 'partial gate cleanup must not mutate encrypted data');
        assert.equal(await ui.lockActiveManager(root), true, 'same-root lock must retry a partial ensure authorization before opening the broker locator');
        assert.equal(fs.existsSync(partialSessionRoot), false, 'confirmed retry should remove the retained preflight directory');
        assert.equal(store.storeStatus(root).currentRevision, revisionBeforePartialGate);

        const noHandle = await ui.createPrivateSession(root, 'cc-switch'); noHandle.discard = true;
        noHandle.usernsCleanupUncertain = true; noHandle.authorizationCleanupError = new Error('synthetic marker without authorization');
        fs.writeFileSync(path.join(noHandle.dir, '.apparmor-cleanup-unconfirmed'), 'synthetic marker', { mode: 0o600 });
        await ui.saveAndRemove(noHandle);
        assert.equal(noHandle.cleaned, undefined, 'a marker without a matching authorization must never be treated as released');
        assert.equal(fs.existsSync(noHandle.dir), true, 'marker-without-handle cleanup must retain the profile attachment tree');
        await assert.rejects(ui.lockActiveManager(root), /清理仍未完成/, 'the public lock action must expose unresolved marker cleanup');
        fs.unlinkSync(path.join(noHandle.dir, '.apparmor-cleanup-unconfirmed'));
        noHandle.usernsCleanupUncertain = false; noHandle.authorizationCleanupError = null;
        await ui.saveAndRemove(noHandle);
        assert.equal(noHandle.cleaned, true, 'synthetic suite cleanup removes its marker after uncertainty is cleared');

        const manuallyRemoved = await ui.createPrivateSession(root, 'cc-switch'); manuallyRemoved.discard = true;
        const exactProfile = 'portable-ai-bwrap-4242-0123456789ab';
        manuallyRemoved.usernsAuthorization = { profile: { name: exactProfile } };
        fs.writeFileSync(path.join(manuallyRemoved.dir, '.apparmor-cleanup-unconfirmed'), 'synthetic marker', { mode: 0o600 });
        const oldReadFileSync = fs.readFileSync, oldManualRelease = usernsApi.releaseSandboxUserns;
        usernsApi.releaseSandboxUserns = async () => { throw new Error('manual unload was needed'); };
        fs.readFileSync = function (file, ...args) {
          if (file === '/sys/kernel/security/apparmor/profiles') return 'unrelated-profile (enforce)\n';
          return oldReadFileSync.call(this, file, ...args);
        };
        try { await ui.saveAndRemove(manuallyRemoved); }
        finally { fs.readFileSync = oldReadFileSync; usernsApi.releaseSandboxUserns = oldManualRelease; }
        assert.equal(manuallyRemoved.cleaned, true, 'a read-only exact-profile absence check should confirm manual unload');
        assert.equal(fs.existsSync(manuallyRemoved.dir), false, 'confirmed unload permits removing the uncertainty marker and private tree');
      } finally {
        runtimeApi.stageRuntime = oldStageAfterGateFailure;
        usernsApi.ensureSandboxUserns = oldEnsureAfterGateFailure;
        usernsApi.releaseSandboxUserns = oldReleaseAfterGateFailure;
      }
    }

    const restoreLifecycle = await ui.createPrivateSession(root, 'claude');
    restoreLifecycle.opened = store.openStore(root, password);
    let normalRelease = 0;
    const originalRelease = usernsApi?.releaseSandboxUserns;
    if (usernsApi) { usernsApi.releaseSandboxUserns = async (authorization) => { assert.equal(authorization.synthetic, 'normal-cleanup'); normalRelease++; }; restoreLifecycle.usernsAuthorization = { synthetic: 'normal-cleanup' }; }
    assert.equal(fs.existsSync(path.join(restoreLifecycle.dir, '.portable-session.json')), false, 'empty private session must not block canonical snapshot restore');
    store.restoreSnapshot(store.readSnapshot(restoreLifecycle.opened), restoreLifecycle.dir);
    ui.writePrivateOwner(restoreLifecycle);
    assert.equal(fs.existsSync(path.join(restoreLifecycle.dir, '.portable-session.json')), true, 'crash metadata is written after snapshot restore');
    await Promise.all([ui.saveAndRemove(restoreLifecycle), ui.saveAndRemove(restoreLifecycle)]);
    if (usernsApi) { usernsApi.releaseSandboxUserns = originalRelease; assert.equal(normalRelease, 1, 'normal close must release its user namespace authorization exactly once'); }
    assert.equal(ui.sessionCount(), 0, 'completed cleanup must remove the session from the process-owned session map');

    const setupFailure = { discard: true }, failedChild = new EventEmitter(); failedChild.exitCode = null; failedChild.signalCode = null; failedChild.sandboxReady = Promise.reject(new Error('synthetic namespace setup failure'));
    await assert.rejects(ui.awaitSandboxReady(setupFailure, failedChild), /synthetic namespace setup failure/);
    assert.equal(setupFailure.discard, true, 'a failed namespace setup must stay on the discard path');
    const launched = { discard: true }, appChild = new EventEmitter(); appChild.exitCode = null; appChild.signalCode = null; appChild.sandboxReady = Promise.resolve();
    await ui.awaitSandboxReady(launched, appChild);
    assert.equal(launched.discard, false, 'session data becomes saveable only after namespace setup readiness');
    setImmediate(() => { appChild.exitCode = 7; appChild.emit('exit', 7, null); });
    assert.deepEqual(await ui.waitForChild(appChild), { code: 7, signal: null }, 'a nonzero application exit remains a launched session that can be archived');
    assert.equal(launched.discard, false, 'a nonzero application exit must not turn a ready session back into a prelaunch discard');

    const stagedRestore = await ui.createPrivateSession(root, 'cc-switch'); stagedRestore.discard = true;
    for (const rel of ['harness/cc-switch/claude', 'config/cc-switch/home/.cc-switch']) fs.mkdirSync(path.join(stagedRestore.dir, rel), { recursive: true, mode: 0o700 });
    const restoreFiles = new Map([
      ['harness/cc-switch/claude/settings.json', Buffer.from('{"synthetic":true}')],
      ['config/cc-switch/home/.cc-switch/settings.json', Buffer.from('{"synthetic":true}')],
    ]);
    await ui.restoreSessionSnapshot(restoreFiles, stagedRestore);
    const stagedSettings = path.join(stagedRestore.dir, 'harness/cc-switch/claude/settings.json');
    assert.equal(fs.readFileSync(stagedSettings, 'utf8'), '{"synthetic":true}');
    assert.equal(fs.statSync(stagedSettings).mode & 0o777, 0o600, 'restored files should be private');
    assert.equal(fs.readdirSync(stagedRestore.dir).some((n) => n.startsWith('.snapshot-validate-')), false, 'temporary plaintext snapshot must always be removed');
    await assert.rejects(ui.restoreSessionSnapshot(restoreFiles, stagedRestore), /EEXIST|already exists|unsafe/i, 'staged restore must refuse to overwrite a file');
    assert.equal(fs.readdirSync(stagedRestore.dir).some((n) => n.startsWith('.snapshot-validate-')), false, 'failed restores must also remove temporary plaintext');
    await assert.rejects(ui.restoreSessionSnapshot(new Map([['../escape.json', Buffer.from('bad')]]), stagedRestore), /unsafe|invalid|relative|path/i, 'restore must reject traversal before copying');
    await ui.saveAndRemove(stagedRestore);

    if (process.platform === 'linux') {
      const symlinkRestore = await ui.createPrivateSession(root, 'cc-switch'); symlinkRestore.discard = true;
      const configRoot = path.join(symlinkRestore.dir, 'harness/cc-switch'); fs.mkdirSync(configRoot, { recursive: true });
      fs.symlinkSync(os.tmpdir(), path.join(configRoot, 'claude'));
      await assert.rejects(ui.restoreSessionSnapshot(new Map([['harness/cc-switch/claude/settings.json', Buffer.from('{}')]]), symlinkRestore), /symbolic link|unsafe|EEXIST/i,
        'restore must reject symlinked staged directories');
      await ui.saveAndRemove(symlinkRestore);
    }

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
    let unplugRelease = 0;
    const originalUnplugRelease = usernsApi?.releaseSandboxUserns;
    if (usernsApi) { usernsApi.releaseSandboxUserns = async (authorization) => { assert.equal(authorization.synthetic, 'unplug-cleanup'); unplugRelease++; }; ccUnplug.usernsAuthorization = { synthetic: 'unplug-cleanup' }; }
    ui.watchForUnplug(ccUnplug, 'CC Switch');
    ccUnplug.identity.mountId = 'synthetic-cc-remount-change';
    const unplugDeadline = Date.now() + 6000;
    while (!ccUnplug.cleaned && Date.now() < unplugDeadline) await new Promise((resolve) => setTimeout(resolve, 100));
    if (usernsApi) { usernsApi.releaseSandboxUserns = originalUnplugRelease; assert.equal(unplugRelease, 1, 'unplug cleanup must release its user namespace authorization'); }
    assert.equal(ccUnplug.cleaned, true, 'CC Switch unplug watcher must stop its owned GUI and encrypt/remove its private session');
    assert.equal(ccChild.exitCode !== null || ccChild.signalCode !== null, true, 'CC Switch unplug cleanup must wait for the owned process to stop');
    const ccRecoveryDir = path.join(os.tmpdir(), `portable-ai-${process.getuid ? process.getuid() : 'user'}`, 'recovery');
    const ccRecovery = path.join(ccRecoveryDir, `${ccUnplug.id}.recovery.json`);
    assert.ok(fs.existsSync(ccRecovery), 'CC Switch unplug must retain an encrypted local recovery bundle');
    await ui.restorePrivateBundle(root, ccRecovery, password);

    const hupState = path.join(root, 'hup-state.json');
    const modulePath = path.resolve(__dirname, 'linux-session.cjs');
    const storePath = path.resolve(__dirname, 'linux-encrypted-store.cjs');
    const usernsPath = path.resolve(__dirname, 'linux-userns.cjs');
    const hupScript = `const fs=require('node:fs'),path=require('node:path'),{spawn}=require('node:child_process'),ui=require(${JSON.stringify(modulePath)}),store=require(${JSON.stringify(storePath)}),userns=require(${JSON.stringify(usernsPath)});userns.releaseSandboxUserns=async()=>{const x=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));x.usernsReleased=true;fs.writeFileSync(process.argv[3],JSON.stringify(x))};(async()=>{const root=process.argv[1],password=process.argv[2],state=process.argv[3],r=await ui.createPrivateSession(root,'claude');r.opened=store.openStore(root,password);r.usernsAuthorization={synthetic:'hup'};r.workHash='${'e'.repeat(64)}';r.claudeConfigDir=path.join(r.dir,'harness','cc-switch','claude');const f=path.join(r.claudeConfigDir,'projects','hup.jsonl');fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,'hup-cleanup-sentinel');const c=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:'ignore'});await new Promise((ok,bad)=>{c.once('spawn',ok);c.once('error',bad)});r.children.add(c);r.managerChild=c;fs.writeFileSync(state,JSON.stringify({dir:r.dir,pid:c.pid,usernsReleased:false}));ui.installExitHandlers();setTimeout(()=>process.kill(process.pid,'SIGHUP'),100)})().catch(e=>{console.error(e);process.exit(2)})`;
    const hupWorker = spawn(process.execPath, ['-e', hupScript, root, password, hupState], { stdio: 'ignore' });
    let hupTimer;
    const hupExit = await Promise.race([
      once(hupWorker, 'exit'),
      new Promise((_, reject) => { hupTimer = setTimeout(() => reject(new Error('synthetic SIGHUP cleanup worker timed out')), 12000); }),
    ]);
    clearTimeout(hupTimer);
    assert.equal(hupExit[0], 129, 'SIGHUP must await owned cleanup before exiting with its conventional status');
    const hup = JSON.parse(fs.readFileSync(hupState, 'utf8'));
    assert.equal(hup.usernsReleased, true, 'SIGHUP cleanup must release its user namespace authorization');
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
    orphanMetadata.owner = { pid: 2147483647, bootId: '11111111-1111-4111-8111-111111111111', start: '1' };
    fs.writeFileSync(ownerFile, JSON.stringify(orphanMetadata), { mode: 0o600 });
    fs.writeFileSync(path.join(orphan.dir, '.apparmor-cleanup-unconfirmed'), 'synthetic stale profile marker', { mode: 0o600 });
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
    assert.equal(ui.sessionCount(), 0, 'completed orphan recovery must release its in-memory session record');

    const blockedOrphan = await ui.createPrivateSession(root, 'claude'); blockedOrphan.opened = store.openStore(root, password);
    blockedOrphan.workHash = 'd'.repeat(64); blockedOrphan.claudeConfigDir = path.join(blockedOrphan.dir, 'harness', 'cc-switch', 'claude');
    const blockedTranscript = path.join(blockedOrphan.claudeConfigDir, 'projects', 'must-retain.jsonl');
    fs.mkdirSync(path.dirname(blockedTranscript), { recursive: true }); fs.writeFileSync(blockedTranscript, 'retained-unconfirmed-profile-data');
    ui.writePrivateOwner(blockedOrphan);
    const blockedOwnerFile = path.join(blockedOrphan.dir, '.portable-session.json');
    const blockedMetadata = JSON.parse(fs.readFileSync(blockedOwnerFile, 'utf8'));
    blockedMetadata.owner = { pid: 2147483647, bootId: fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim(), start: '1' };
    fs.writeFileSync(blockedOwnerFile, JSON.stringify(blockedMetadata), { mode: 0o600 });
    fs.writeFileSync(path.join(blockedOrphan.dir, '.apparmor-cleanup-unconfirmed'), 'synthetic active-boot uncertainty', { mode: 0o600 });
    const unchangedRevision = store.storeStatus(root).currentRevision;
    await assert.rejects(ui.recoverOrphanSession(root, blockedOrphan.dir, 'wrong-synthetic-password'), /AppArmor cleanup was not confirmed/, 'the marker guard must run before password validation');
    assert.equal(fs.existsSync(blockedOrphan.dir), true, 'same-boot uncertain policy marker must preserve plaintext directory');
    assert.equal(store.storeStatus(root).currentRevision, unchangedRevision, 'refused marked orphan recovery must not change encrypted revision');
    let orphanSkipMessage = '';
    const oldError = console.error;
    console.error = (message) => { orphanSkipMessage += `${message}\n`; };
    try { await ui.recoverOrphanSessions(root); }
    finally { console.error = oldError; }
    assert.match(orphanSkipMessage, /不请求密码/,'automatic recovery must skip marked current-boot orphans before password prompts');
    assert.equal(fs.existsSync(blockedOrphan.dir), true);

    const invalidBootOrphan = await ui.createPrivateSession(root, 'claude'); invalidBootOrphan.opened = store.openStore(root, password);
    invalidBootOrphan.workHash = 'f'.repeat(64); invalidBootOrphan.claudeConfigDir = path.join(invalidBootOrphan.dir, 'harness', 'cc-switch', 'claude');
    ui.writePrivateOwner(invalidBootOrphan);
    const invalidOwnerFile = path.join(invalidBootOrphan.dir, '.portable-session.json');
    const invalidMetadata = JSON.parse(fs.readFileSync(invalidOwnerFile, 'utf8'));
    invalidMetadata.owner = { pid: 2147483647, bootId: 'unknown', start: '1' };
    fs.writeFileSync(invalidOwnerFile, JSON.stringify(invalidMetadata), { mode: 0o600 });
    fs.writeFileSync(path.join(invalidBootOrphan.dir, '.apparmor-cleanup-unconfirmed'), 'synthetic invalid boot identity', { mode: 0o600 });
    await assert.rejects(ui.recoverOrphanSession(root, invalidBootOrphan.dir, password), /AppArmor cleanup was not confirmed/);
    assert.equal(fs.existsSync(invalidBootOrphan.dir), true, 'unknown owner boot identity must preserve marked orphan');
    blockedOrphan.opened.close(); invalidBootOrphan.opened.close();
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
  for (const name of ['ai.cjs', 'linux-session.cjs', 'linux-encrypted-store.cjs', 'linux-runtime.cjs', 'linux-sandbox.cjs', 'linux-native-proxy.cjs', 'linux-userns.cjs']) {
    if (!fs.existsSync(path.join(__dirname, name))) continue;
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
    await waitFor('portable Linux runtime is incomplete');
    await waitFor('请选择：'); child.stdin.write('0\n');
    const [code] = await Promise.race([once(child, 'exit'), new Promise((_, reject) => setTimeout(() => reject(new Error('PTY first-run CLI did not exit')), 8000))]);
    assert.equal(code, 0, `first-run CLI failed: ${output}`);
    assert.equal(output.includes('synthetic-pty-password'), false, 'masked master password must never appear in terminal output');
    assert.equal(store.storeStatus(fixture).state, 'Absent', 'runtime refusal must happen before a first-run master password can create a vault');

    // Keep a real masked-password TTY check, separated from first-run settings
    // so it cannot create a vault merely to exercise the input widget.
    const probe = spawn('/usr/bin/script', ['-qec', `${quote(process.execPath)} -e ${quote(`require(${JSON.stringify(path.join(scripts, 'linux-session.cjs'))}).askSecret('Synthetic password probe').then(()=>process.exit(0),()=>process.exit(1))`)}`, '/dev/null'], {
      cwd: project, env: { PATH: '/usr/bin:/bin', HOME: fixture, TMPDIR: tmp, TERM: 'xterm', LANG: 'C.UTF-8' }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    let probeOutput = '';
    probe.stdout.on('data', (b) => { probeOutput += b.toString(); }); probe.stderr.on('data', (b) => { probeOutput += b.toString(); });
    await new Promise((resolve, reject) => { probe.once('error', reject); probe.once('spawn', resolve); });
    await new Promise((resolve) => setTimeout(resolve, 100)); probe.stdin.write('synthetic-pty-password\n');
    const [probeCode] = await once(probe, 'exit');
    assert.equal(probeCode, 0, 'TTY password input should still work');
    assert.equal(probeOutput.includes('synthetic-pty-password'), false, 'masked password probe must not echo the typed secret');
    console.log('Synthetic TTY preflight refusal and masked password checks passed.');
  } finally {
    if (child.exitCode === null) { child.kill('SIGTERM'); await Promise.race([once(child, 'exit'), new Promise((resolve) => setTimeout(resolve, 1000))]); }
    fs.rmSync(fixture, { recursive: true, force: true });
  }
}

run().catch((e) => { console.error(e); process.exitCode = 1; });
