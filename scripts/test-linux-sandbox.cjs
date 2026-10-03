'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { stageRuntime } = require('./linux-runtime.cjs');
const { buildSandbox, launchSandbox } = require('./linux-sandbox.cjs');
const { probeUserns } = require('./linux-userns.cjs');

function run(spec, timeout = 20000) {
  const r = spawnSync(spec.executable, spec.args, { env: spec.env, cwd: path.dirname(spec.executable), encoding: 'utf8', timeout });
  if (r.error) throw r.error;
  assert.equal(r.status, 0, `sandbox command failed (${r.status}): ${r.stderr}`);
  return r.stdout;
}
function childDone(child, ms) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
  return new Promise(resolve => {
    let done = false;
    const finish = value => { if (!done) { done = true; clearTimeout(timer); resolve(value); } };
    child.once('exit', (code, signal) => finish({ code, signal }));
    const timer = setTimeout(() => finish(null), ms);
  });
}
async function main() {
  const root = path.resolve(process.argv[2] || process.env.AISTICK_ROOT || '..');
  const gui = process.argv.includes('--gui');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-linux-sandbox-'));
  const secret = path.join(temp, 'host-secret.txt');
  const workDir = path.join(temp, 'work');
  fs.mkdirSync(workDir); fs.writeFileSync(secret, 'host-only');
  const staged = stageRuntime(root, path.join(temp, 'session-one'));
  try {
    const userns = probeUserns(staged);
    assert.ok(userns.ok, `staged bubblewrap user namespace probe failed (${userns.kind}): ${userns.stderr || userns.error?.message || 'no diagnostic'}`);
    const managerProbe = [
      'const fs=require("node:fs");',
      `if(fs.existsSync(${JSON.stringify(secret)})) process.exit(31);`,
      'if(fs.existsSync("/etc/npmrc"))process.exit(33);',
      'fs.writeFileSync("/home/portable/manager-probe","confined");',
      'fs.writeFileSync("/harness/cc-switch/manager-probe","confined");',
      'try{fs.writeFileSync("/etc/aistick-host-write-probe","x");process.exit(32)}catch{}',
      'process.stdout.write("manager isolation ok\\n");',
    ].join('');
    const manager = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'cc-switch', command: staged.node, args: ['-e', managerProbe], network: false });
    assert.ok(manager.args.includes('--unshare-net'));
    assert.ok(!manager.args.some((value, index) => value === '--ro-bind' && manager.args[index + 1] === '/etc' && manager.args[index + 2] === '/etc'), 'the host /etc tree must never be bind-mounted');
    assert.match(run(manager), /manager isolation ok/);
    assert.equal(fs.readFileSync(path.join(staged.home, 'manager-probe'), 'utf8'), 'confined');
    assert.equal(fs.readFileSync(path.join(staged.ccConfig, 'manager-probe'), 'utf8'), 'confined');
    assert.equal(fs.existsSync('/etc/aistick-host-write-probe'), false);

    const syntheticToken = 'aistick-synthetic-secret-argv-check-7f99';
    const secretSpec = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude',
      command: staged.node, args: ['-e', 'setTimeout(()=>process.exit(0),1500)'], workDir,
      network: false, extraEnv: { ANTHROPIC_AUTH_TOKEN: syntheticToken } });
    assert.ok(!secretSpec.args.join('\0').includes(syntheticToken), 'provider token must not be in the bubblewrap argv');
    const originalSecretArgs = [...secretSpec.args];
    const secretChild = launchSandbox(secretSpec, { stdio: 'ignore', trackSetup: true });
    await secretChild.sandboxReady;
    assert.deepEqual(secretSpec.args, originalSecretArgs, 'tracked launch must not mutate the reusable sandbox spec');
    const cmdline = fs.readFileSync(`/proc/${secretChild.pid}/cmdline`, 'utf8');
    assert.ok(!cmdline.includes(syntheticToken), 'provider token must not appear in /proc cmdline');
    const secretExit = await childDone(secretChild, 10000);
    assert.deepEqual(secretExit, { code: 0, signal: null }, 'sandbox accepts provider env over the private args pipe');

    const nonzero = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude', command: staged.node,
      args: ['-e', 'process.exitCode=7'], workDir, network: false });
    const nonzeroChild = launchSandbox(nonzero, { stdio: 'ignore', trackSetup: true });
    await nonzeroChild.sandboxReady;
    assert.deepEqual(await childDone(nonzeroChild, 10000), { code: 7, signal: null }, 'readiness resolves independently of a later application exit code');

    const failedChild = launchSandbox({ executable: '/bin/false', args: ['/bin/true'], commandOffset: 0, env: process.env },
      { stdio: 'ignore', trackSetup: true, readyTimeout: 3000 });
    await assert.rejects(failedChild.sandboxReady, /exited before namespace setup completed|readiness pipe/);

    const slowBwrap = path.join(temp, 'slow-bwrap');
    fs.writeFileSync(slowBwrap, '#!/bin/sh\nexec /usr/bin/sleep 5\n', { mode: 0o700 });
    const timedChild = launchSandbox({ executable: slowBwrap, args: ['--', '/bin/true'], commandOffset: 1, env: process.env },
      { stdio: 'ignore', trackSetup: true, readyTimeout: 30 });
    await assert.rejects(timedChild.sandboxReady, /readiness timed out/);
    timedChild.kill('SIGKILL');
    await childDone(timedChild, 5000);

    if (process.argv.includes('--tty')) {
      const ttySpec = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude',
        command: staged.node, args: ['-e', 'if(!process.stdin.isTTY)process.exit(61);process.exit(0)'],
        workDir, network: false, extraEnv: { ANTHROPIC_AUTH_TOKEN: syntheticToken } });
      const ttyChild = launchSandbox(ttySpec, { trackSetup: true });
      await ttyChild.sandboxReady;
      const ttyExit = await childDone(ttyChild, 10000);
      assert.deepEqual(ttyExit, { code: 0, signal: null }, 'Claude stdin remains a readable TTY while a provider secret is piped to bubblewrap');
    }

    const claudeProbe = [
      'const fs=require("node:fs");',
      `if(fs.existsSync(${JSON.stringify(secret)})) process.exit(41);`,
      `if(fs.existsSync(${JSON.stringify(staged.home)})) process.exit(42);`,
      'fs.writeFileSync("/workspace/portable-work-probe","workspace-write");',
      'process.stdout.write("claude workspace ok\\n");',
    ].join('');
    const claude = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude', command: staged.node, args: ['-e', claudeProbe], workDir, network: false });
    assert.deepEqual(claude.display.targets, [], 'Claude terminal session must not proxy host display sockets');
    assert.ok(!claude.args.includes('/tmp/.X11-unix') && !claude.args.includes('/run/user/0'), 'Claude terminal session must not bind host display socket paths');
    assert.ok(!claude.args.includes('DISPLAY') && !claude.args.includes('WAYLAND_DISPLAY') && !claude.env.DISPLAY && !claude.env.WAYLAND_DISPLAY, 'Claude terminal session must not receive desktop variables');
    assert.ok(claude.args.some((value, index) => value === 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' && claude.args[index + 1] === '1'), 'Claude sessions disable nonessential telemetry and self-update traffic');
    assert.match(run(claude), /claude workspace ok/);
    assert.equal(fs.readFileSync(path.join(workDir, 'portable-work-probe'), 'utf8'), 'workspace-write');
    assert.equal(fs.existsSync(secret), true);
    const claudeVersion = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude', command: staged.claude, args: ['--version'], workDir, network: false });
    assert.match(run(claudeVersion), /Claude Code/i);
    const gitVersion = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude', command: staged.git, args: ['--version'], workDir, network: false });
    assert.match(run(gitVersion), /^git version /);

    fs.writeFileSync(path.join(workDir, 'pyproject.toml'), '[project]\nname = "aistick-sandbox-probe"\nversion = "0.0.0"\nrequires-python = ">=3.12"\n');
    const uvRun = buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'claude', command: staged.uv,
      args: ['run', '--offline', 'python', '-c', 'import sys;print(sys.executable)'], workDir, network: false });
    const uvOutput = run(uvRun).trim();
    assert.match(uvOutput, /^\/home\/portable\/\.venv\/bin\/python/);
    assert.equal(fs.existsSync(path.join(workDir, '.venv')), false, 'uv must keep executable environments out of a FAT/noexec project directory');
    assert.equal(fs.lstatSync(path.join(staged.claudeHome, '.venv', 'bin', 'python')).isSymbolicLink(), true, 'uv must build its environment from the staged private Python runtime');

    // Separate session trees can execute at the same time without sharing HOME.
    const stagedTwo = stageRuntime(root, path.join(temp, 'session-two'));
    const launches = [staged, stagedTwo].map((rt, index) => launchSandbox(buildSandbox({
      sessionRoot: rt.sessionRoot, runtime: rt, mode: 'cc-switch', command: rt.node,
      args: ['-e', `require("node:fs").writeFileSync("/home/portable/concurrency","${index}")`], network: false,
    }), { stdio: 'ignore' }));
    const results = await Promise.all(launches.map(child => childDone(child, 15000)));
    assert.deepEqual(results, [{ code: 0, signal: null }, { code: 0, signal: null }]);
    assert.equal(fs.readFileSync(path.join(staged.home, 'concurrency'), 'utf8'), '0');
    assert.equal(fs.readFileSync(path.join(stagedTwo.home, 'concurrency'), 'utf8'), '1');

    if (gui) {
      const app = launchSandbox(buildSandbox({ sessionRoot: staged.sessionRoot, runtime: staged, mode: 'cc-switch', command: staged.ccSwitch, args: [], network: true }), { stdio: 'ignore', trackSetup: true });
      await app.sandboxReady;
      const earlyExit = await childDone(app, 12000);
      if (earlyExit) throw new Error(`CC Switch GUI exited during WSLg smoke launch (${JSON.stringify(earlyExit)})`);
      process.kill(-app.pid, 'SIGTERM');
      const stopped = await childDone(app, 8000);
      if (!stopped) process.kill(-app.pid, 'SIGKILL');
      assert.ok(stopped, 'CC Switch GUI session did not clean up after its process group was stopped');
      process.stdout.write('CC Switch AppImage stayed running under WSLg for 12 seconds and cleaned up.\n');
    }
    process.stdout.write('namespace isolation, read-only host boundary, private HOME, workspace write, offline mode and concurrent sessions passed.\n');
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}
main().catch(e => { process.stderr.write(`${e.stack || e}\n`); process.exitCode = 1; });
