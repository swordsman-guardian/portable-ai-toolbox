'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const { PassThrough, Writable } = require('node:stream');
const { spawnSync } = require('node:child_process');
const {
  CONSENT_TOKEN, CLEANUP_UNCONFIRMED_MARKER, LOADED, STATIC_HELPER, parserPath, usernsRestriction, usernsGlobalBlock, sandboxProfileText,
  probeUserns, ensureSandboxUserns, releaseSandboxUserns,
} = require('./linux-userns.cjs');
const { sandboxExecEnv } = require('./linux-sandbox.cjs');

function runtimeTree() {
  const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'userns-private-'));
  fs.chmodSync(sessionRoot, 0o700);
  const runtimeRoot = path.join(sessionRoot, 'runtime'); fs.mkdirSync(runtimeRoot, { mode: 0o700 });
  const sandboxRoot = path.join(runtimeRoot, 'sandbox'); fs.mkdirSync(sandboxRoot, { mode: 0o700 });
  const bwrapDir = path.join(runtimeRoot, 'bin'); fs.mkdirSync(bwrapDir, { mode: 0o700 });
  const bwrap = path.join(bwrapDir, 'bwrap'); fs.writeFileSync(bwrap, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  return { sessionRoot, runtimeRoot, sandboxRoot, bwrap };
}

function fakeHooks({ ready = true, closeCode = 0, holdOpen = false } = {}) {
  const state = { calls: [], child: null, inputClosed: false, loaded: false, unloaded: false };
  const hooks = {
    parserStat: () => ({ isFile: () => true, isSymbolicLink: () => false, uid: 0, mode: 0o100755 }),
    sudoStat: () => ({ isFile: () => true, isSymbolicLink: () => false, uid: 0, mode: 0o100755 }),
    spawnSync: (file, args, opts) => {
      state.calls.push({ file, args, opts });
      return { status: 0, stdout: '', stderr: '' };
    },
    spawn: (file, args, opts) => {
      state.calls.push({ file, args, opts });
      const child = new EventEmitter();
      child.exitCode = null; child.signalCode = null;
      child.stdout = new PassThrough(); child.stderr = new PassThrough();
      child.stdin = new Writable({ write(_chunk, _enc, cb) { cb(); } });
      child.finishExit = code => {
        state.unloaded = code === 0; child.exitCode = code; child.emit('exit', code, null); child.emit('close', code, null);
      };
      child.stdin.end = () => {
        state.inputClosed = true;
        if (!holdOpen) setImmediate(() => child.finishExit(closeCode));
      };
      state.child = child; state.loaded = true;
      if (ready) setImmediate(() => child.stdout.write(`PORTABLE_APPARMOR_AUTHENTICATED\n${LOADED}PORTABLE_APPARMOR_READY\n`));
      return child;
    },
  };
  return { hooks, state };
}

async function main() {
  const root = runtimeTree();
  try {
    const apparmorSysctl = path.join(root.sessionRoot, 'apparmor_restrict_unprivileged_userns');
    fs.writeFileSync(apparmorSysctl, '1\n'); assert.equal(usernsRestriction(apparmorSysctl), 1);
    fs.writeFileSync(apparmorSysctl, '0\n'); assert.equal(usernsRestriction(apparmorSysctl), 0);
    const globalSysctl = path.join(root.sessionRoot, 'max_user_namespaces');
    fs.writeFileSync(globalSysctl, '0\n'); assert.equal(usernsGlobalBlock([globalSysctl]), globalSysctl);
    fs.writeFileSync(globalSysctl, '1000\n'); assert.equal(usernsGlobalBlock([globalSysctl]), null);
    const env = sandboxExecEnv(root.runtimeRoot, root.sandboxRoot);
    assert.equal(env.PATH, '/usr/bin:/bin');
    assert.ok(!Object.keys(env).some(k => ['HOME', 'SUDO_ASKPASS', 'APPARMOR_PROFILE'].includes(k)));

    const profile = sandboxProfileText(root);
    assert.equal(profile.attachment, root.bwrap);
    assert.match(profile.name, /^portable-ai-bwrap-\d+-[0-9a-f]{12}$/);
    assert.match(profile.text, new RegExp(`profile ${profile.name} "${root.bwrap.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`));
    assert.match(profile.text, /^abi <abi\/4\.0>,\nprofile .* flags=\(unconfined\) \{\n  userns,\n\}\n$/);
    assert.doesNotMatch(profile.text, /\*[^\n]*\{/);
    const linked = path.join(root.runtimeRoot, 'link'); fs.symlinkSync(root.bwrap, linked);
    assert.throws(() => sandboxProfileText({ ...root, bwrap: linked }), /symbolic links|canonical/);
    fs.unlinkSync(linked);
    assert.equal(sandboxProfileText(root).name, profile.name, 'profile name is deterministic for the same user and executable');
    fs.chmodSync(root.bwrap, 0o4700);
    assert.throws(() => sandboxProfileText(root), /setuid or setgid/);
    fs.chmodSync(root.bwrap, 0o700);
    fs.chmodSync(root.sessionRoot, 0o755);
    assert.throws(() => sandboxProfileText(root), /private mode 700/);
    fs.chmodSync(root.sessionRoot, 0o700);

    const capture = {};
    const successfulProbe = probeUserns(root, { spawnSync: (file, args, opts) => { Object.assign(capture, { file, args, opts }); return { status: 0, stdout: '', stderr: '' }; } });
    assert.equal(successfulProbe.kind, 'ok');
    assert.deepEqual(capture.args, ['--unshare-user', '--uid', '0', '--gid', '0', '--ro-bind', '/', '/', '/usr/bin/true']);
    assert.equal(capture.opts.timeout, 5000);
    assert.equal(capture.opts.env.PATH, env.PATH);
    assert.equal(probeUserns(root, { spawnSync: () => ({ status: 1, stderr: 'bwrap: Permission denied' }) }).kind, 'namespace-permission');
    assert.equal(probeUserns(root, { spawnSync: () => ({ error: { code: 'ETIMEDOUT' }, status: null, stderr: '' }) }).kind, 'timeout');
    assert.equal(probeUserns(root, { spawnSync: () => ({ error: { code: 'ENOENT' }, status: null, stderr: '' }) }).kind, 'loader');
    assert.equal(probeUserns(root, { spawnSync: () => ({ status: 127, stderr: 'error while loading shared libraries: libbwrap.so: Permission denied' }) }).kind, 'loader');

    let sudoCalls = 0;
    await assert.rejects(ensureSandboxUserns(root, { probe: () => ({ ok: true }), isTTY: false }), /fixed:false|never/).catch(() => {});
    const direct = await ensureSandboxUserns(root, { probe: () => ({ ok: true }) });
    assert.deepEqual(direct, { fixed: false, authorization: null });
    assert.equal(fs.existsSync(path.join(root.sessionRoot, CLEANUP_UNCONFIRMED_MARKER)), false, 'normal startup without a privileged profile creates no cleanup marker');

    const deniedProbe = () => ({ ok: false, kind: 'namespace-permission', stderr: 'Operation not permitted' });
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 0 }), /not confirmed/);
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 1,
      globalBlock: () => '/proc/sys/user/max_user_namespaces', ask: async () => { throw new Error('consent should not run'); } }), /disabled by/);
    const failSyntax = fakeHooks(); failSyntax.hooks.spawnSync = () => ({ status: 1, stderr: 'syntax error' });
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true,
      hooks: failSyntax.hooks, globalBlock: () => null, ask: async () => { throw new Error('consent should not run'); } }), /syntax check failed/);
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: false,
      hooks: { parserStat: () => ({ isFile: () => true, isSymbolicLink: () => false, uid: 0, mode: 0o100755 }), spawnSync: () => ({ status: 0 }) }, globalBlock: () => null }), /needs one-time authorization in a TTY/);
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true,
      hooks: { parserStat: () => ({ isFile: () => true, isSymbolicLink: () => false, uid: 0, mode: 0o100755 }), spawnSync: () => ({ status: 0 }) }, globalBlock: () => null, ask: async () => 'no' }), /declined/);

    const applyFail = fakeHooks({ ready: false });
    const baseLaunch = applyFail.hooks.spawn;
    applyFail.hooks.spawn = (...args) => {
      const child = baseLaunch(...args);
      setImmediate(() => { child.exitCode = 88; child.emit('exit', 88, null); child.emit('close', 88, null); });
      return child;
    };
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true,
      hooks: applyFail.hooks, globalBlock: () => null, ask: async () => CONSENT_TOKEN }), /exited before readiness/);
    assert.equal(fs.existsSync(path.join(root.sessionRoot, CLEANUP_UNCONFIRMED_MARKER)), false, 'failed profile application without a loaded profile creates no marker');

    const markerLost = fakeHooks({ ready: false, closeCode: 89 });
    const markerLostLaunch = markerLost.hooks.spawn;
    markerLost.hooks.spawn = (...args) => { const child = markerLostLaunch(...args); setImmediate(() => child.finishExit(89)); return child; };
    await assert.rejects(ensureSandboxUserns(root, { probe: deniedProbe, restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true,
      hooks: markerLost.hooks, globalBlock: () => null, ask: async () => CONSENT_TOKEN }), error => {
      assert.match(error.message, /sudo \/usr\/sbin\/apparmor_parser -K -R/);
      assert.ok(error.message.includes(profile.text));
      assert.ok(error.usernsAuthorization, 'startup cleanup error retains its opaque authorization');
      return true;
    }, 'exit 89 must report cleanup even when no authenticated or loaded marker arrived');
    assert.equal(fs.readFileSync(path.join(root.sessionRoot, CLEANUP_UNCONFIRMED_MARKER), 'utf8'), 'AppArmor profile cleanup could not be confirmed.\n');

    const fake = fakeHooks(); let firstProbe = true;
    const ensured = await ensureSandboxUserns(root, { probe: () => { if (firstProbe) { firstProbe = false; return deniedProbe(); } return { ok: true }; }, restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true,
      hooks: fake.hooks, globalBlock: () => null, ask: async prompt => { assert.match(prompt, new RegExp(CONSENT_TOKEN)); return CONSENT_TOKEN; } });
    assert.equal(ensured.fixed, true); assert.ok(ensured.authorization);
    const loadCall = fake.state.calls.find(call => call.file === '/usr/bin/sudo');
    assert.ok(loadCall);
    assert.equal(loadCall.args[0], '--');
    assert.equal(loadCall.args[1], '/bin/sh');
    assert.equal(loadCall.args[2], '-c');
    assert.equal(loadCall.args[3], STATIC_HELPER);
    assert.equal(loadCall.args[6], ensured.authorization.profile.name);
    assert.match(loadCall.args[3], /-K -a/, 'profile load uses add-only semantics');
    assert.doesNotMatch(loadCall.args[3], /-r|--replace/, 'helper never requests profile replacement');
    assert.deepEqual(loadCall.opts.stdio, ['pipe', 'pipe', 'pipe']);
    assert.equal(loadCall.opts.env.PATH, '/usr/bin:/bin');
    assert.equal(loadCall.opts.env.LANG, 'C.UTF-8');
    assert.equal(loadCall.opts.env.LC_ALL, 'C');
    assert.equal(await releaseSandboxUserns(ensured.authorization), undefined);
    assert.equal(fake.state.inputClosed, true);
    assert.equal(fake.state.unloaded, true);
    await releaseSandboxUserns(ensured.authorization);
    assert.equal(fake.state.calls.filter(call => call.file === '/usr/bin/sudo').length, 1);

    const unloadFail = fakeHooks({ closeCode: 89 }); let unloadProbe = true;
    const unloadAuth = await ensureSandboxUserns(root, { probe: () => { if (unloadProbe) { unloadProbe = false; return deniedProbe(); } return { ok: true }; },
      restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true, hooks: unloadFail.hooks,
      globalBlock: () => null, ask: async () => CONSENT_TOKEN });
    await assert.rejects(releaseSandboxUserns(unloadAuth.authorization), error => {
      assert.match(error.message, /sudo \/usr\/sbin\/apparmor_parser -K -R/);
      assert.ok(error.message.includes(unloadAuth.authorization.profile.text));
      return true;
    });
    assert.equal(fs.existsSync(path.join(root.sessionRoot, CLEANUP_UNCONFIRMED_MARKER)), true);

    const delayedClose = fakeHooks({ holdOpen: true }); let delayedProbe = true;
    const delayedAuth = await ensureSandboxUserns(root, { probe: () => { if (delayedProbe) { delayedProbe = false; return deniedProbe(); } return { ok: true }; },
      restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true, hooks: delayedClose.hooks,
      globalBlock: () => null, ask: async () => CONSENT_TOKEN });
    await assert.rejects(releaseSandboxUserns(delayedAuth.authorization, { releaseTimeout: 10 }), /could not be confirmed/);
    assert.equal(fs.existsSync(path.join(root.sessionRoot, CLEANUP_UNCONFIRMED_MARKER)), true);
    delayedClose.state.child.finishExit(0);
    await releaseSandboxUserns(delayedAuth.authorization);
    assert.equal(fs.existsSync(path.join(root.sessionRoot, CLEANUP_UNCONFIRMED_MARKER)), false, 'confirmed retry removes the marker');

    const throwingProbeFake = fakeHooks(); let throwingCount = 0;
    await assert.rejects(ensureSandboxUserns(root, { probe: () => { if (throwingCount++ === 0) return deniedProbe(); throw new Error('injected reprobe failure'); },
      restriction: () => 1, parser: '/usr/sbin/apparmor_parser', isTTY: true, hooks: throwingProbeFake.hooks,
      globalBlock: () => null, ask: async () => CONSENT_TOKEN }), /injected reprobe failure/);
    assert.equal(throwingProbeFake.state.inputClosed, true, 'a thrown re-probe also unloads the temporary profile');

    const reprobeFake = fakeHooks(); let probes = 0;
    await assert.rejects(ensureSandboxUserns(root, { probe: () => ++probes === 1 ? deniedProbe() : { ok: false, kind: 'namespace-permission' },
      restriction: () => 1, globalBlock: () => null, parser: '/usr/sbin/apparmor_parser', isTTY: true, hooks: reprobeFake.hooks, ask: async () => CONSENT_TOKEN }), /still fails/);
    assert.equal(reprobeFake.state.inputClosed, true, 'failed verification unloads the temporary profile');
    assert.match(STATIC_HELPER, /parser.*-K -a/s);
    assert.match(STATIC_HELPER, /profile_text \| "\$parser" -K -R/);
    assert.doesNotMatch(STATIC_HELPER, /eval|source /);
    const shellSyntax = spawnSync('/bin/sh', ['-n'], { input: STATIC_HELPER, encoding: 'utf8' });
    assert.equal(shellSyntax.status, 0, `static privileged helper has invalid shell syntax: ${shellSyntax.stderr}`);

    const actualParser = parserPath();
    if (actualParser) {
      const compiled = spawnSync(actualParser, ['-Q', '-K'], { input: profile.text, encoding: 'utf8', timeout: 10000 });
      assert.equal(compiled.status, 0, `local AppArmor parser rejected generated profile: ${compiled.stderr}`);
    }
    process.stdout.write('AppArmor userns profile validation, probe classification, consent gates, helper lifetime and cleanup checks passed.\n');
  } finally { fs.rmSync(root.sessionRoot, { recursive: true, force: true }); }
}

main().catch(error => { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1; });
