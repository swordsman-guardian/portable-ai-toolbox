'use strict';

// Synthetic bootstrap-gate tests. These use the real shell source for syntax,
// continuation rejection, and the guard/bwrap wrappers, but replace consent,
// bwrap, and the continuation with local fakes; no sudo or network is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { sandboxExecEnv } = require('./linux-sandbox.cjs');

const scripts = __dirname;
const bootstrap = path.join(scripts, 'bootstrap-linux.sh');
const source = fs.readFileSync(bootstrap, 'utf8');
const linux = process.platform === 'linux';

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 20000, ...options });
  if (result.error) throw result.error;
  return result;
}
function shellQuote(value) { return `'${String(value).replaceAll("'", "'\\''")}'`; }
function assertOk(result, message) {
  assert.equal(result.status, 0, `${message}\n${result.stderr || ''}`);
}

async function main() {
  assert.ok(source.endsWith('\n'), 'bootstrap source ends with LF');
  assert.ok(!source.includes('\r'), 'bootstrap source uses LF line endings');
  const gateAt = source.indexOf('# The guard keeps the exact approved profile loaded');
  const gitAt = source.indexOf('(cd "$WORK/git/debs" && apt-get download git');
  const npmAt = source.indexOf('npm-cli.js install --global');
  const manifestAt = source.indexOf('"$RT/manifest.json" "$ROOT" "$NODE_VER"');
  const activeSwitchAt = source.indexOf('mv -f -- "$NPM/active.json.next" "$NPM/active.json"');
  const successAt = source.indexOf('echo "Linux x86_64 portable assets prepared at: $ROOT"');
  assert.ok(gateAt >= 0 && gitAt > gateAt && npmAt > gateAt, 'authorization gate precedes Git and all npm work');
  assert.ok(manifestAt >= 0 && activeSwitchAt > manifestAt && successAt > activeSwitchAt,
    'active.json switches only after the completed asset manifest');
  const beforeGuard = source.slice(0, gateAt);
  for (const write of [
    'cp -- "$WORK/$NODE_FILE" "$RT/node-runtime.tar.xz"',
    'cp -- "$WORK/uv.tar.gz" "$RT/uv-runtime.tar.gz"',
    'cp -- "$WORK/cc-switch.AppImage" "$RT/cc-switch.AppImage"',
    'tar -C "$WORK/bwrap/root" -czf "$RT/bwrap-runtime.tar.gz"',
    'mkdir -p -- "$RT" "$TOOLS" "$NPM"',
  ]) assert.ok(!beforeGuard.includes(write), `prepared assets are not written to the portable root before consent: ${write}`);
  assert.ok(beforeGuard.includes('cp -- "$RT/cc-switch.AppImage" "$WORK/cc-switch.AppImage"'),
    'a verified existing CC Switch image is staged in WORK before consent');
  assert.ok(beforeGuard.includes('tar -C "$WORK/bwrap/root" -czf "$WORK/bwrap-runtime.tar.gz"'),
    'the bubblewrap archive is staged in WORK before consent');
  assert.match(source, /run_bubblewrap\(\)\s*\{\s*bwrap_exec /, 'actual lifecycle invocations pass through the loader-aware bwrap wrapper');
  assert.match(source, /sandboxExecEnv\(process\.argv\[2\],process\.argv\[3\]\)/, 'bootstrap derives its loader path from the shared sandbox helper');

  if (!linux) {
    console.log('Linux bootstrap userns source checks passed; execution fixtures require Linux.');
    return;
  }

  assertOk(run('bash', ['-n', bootstrap]), 'bash syntax check');

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-bootstrap-userns-test-'));
  try {
    const root = path.join(temp, 'portable-root');
    const work = path.join(temp, 'aistick-linux-bootstrap-owned');
    const preparedAssets = path.join(root, 'runtime', 'linux-x64');
    fs.mkdirSync(preparedAssets, { recursive: true });
    const preparedFiles = new Map();
    for (const name of ['node-runtime.tar.xz', 'uv-runtime.tar.gz', 'cc-switch.AppImage', 'bwrap-runtime.tar.gz']) {
      const file = path.join(preparedAssets, name);
      const bytes = Buffer.from(`preexisting-${name}\n`);
      fs.writeFileSync(file, bytes); preparedFiles.set(file, bytes.toString('base64'));
    }
    const assertPreparedUnchanged = label => {
      for (const [file, bytes] of preparedFiles) assert.equal(fs.readFileSync(file).toString('base64'), bytes, `${label}: ${path.basename(file)} remains intact`);
    };
    fs.mkdirSync(path.join(root, 'npm-global', 'linux-x64'), { recursive: true });
    fs.writeFileSync(path.join(root, 'npm-global', 'linux-x64', 'active.json'), '{"slot":"original"}\n');
    fs.mkdirSync(work, { mode: 0o700 });
    fs.chmodSync(work, 0o700);
    fs.mkdirSync(path.join(work, 'bwrap', 'sandbox', 'lib', 'x86_64-linux-gnu'), { recursive: true });
    fs.mkdirSync(path.join(work, 'bwrap', 'sandbox', 'lib64'), { recursive: true });
    const expectedLoaderPath = sandboxExecEnv(work, path.join(work, 'bwrap')).LD_LIBRARY_PATH;
    const before = fs.readFileSync(path.join(root, 'npm-global', 'linux-x64', 'active.json'), 'utf8');

    const malformed = run('bash', [bootstrap, '--continue', root, path.join(temp, 'missing')]);
    assert.notEqual(malformed.status, 0, 'missing continuation workspace is rejected');
    assert.match(malformed.stderr, /Rejected continuation/);
    const symlink = path.join(temp, 'aistick-linux-bootstrap-link');
    fs.symlinkSync(work, symlink);
    const foreign = run('bash', [bootstrap, '--continue', root, symlink]);
    assert.notEqual(foreign.status, 0, 'symlink continuation workspace is rejected');
    assert.match(foreign.stderr, /Rejected continuation/);
    const foreignDirectory = path.join(temp, 'foreign-work');
    fs.mkdirSync(foreignDirectory, { mode: 0o700 });
    fs.chmodSync(foreignDirectory, 0o700);
    const foreignNamed = run('bash', [bootstrap, '--continue', root, foreignDirectory]);
    assert.notEqual(foreignNamed.status, 0, 'unrecognized continuation workspace is rejected');
    assert.match(foreignNamed.stderr, /not an owned bootstrap workspace/);
    const forged = path.join(temp, 'aistick-linux-bootstrap.forged');
    fs.mkdirSync(path.join(forged, 'node', 'bin'), { recursive: true, mode: 0o700 });
    fs.mkdirSync(path.join(forged, 'bwrap', 'root', 'usr', 'bin'), { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(forged, 'node', 'bin', 'node'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    fs.chmodSync(path.join(forged, 'node', 'bin', 'node'), 0o700);
    fs.writeFileSync(path.join(forged, 'bwrap', 'root', 'usr', 'bin', 'bwrap'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    fs.chmodSync(path.join(forged, 'bwrap', 'root', 'usr', 'bin', 'bwrap'), 0o700);
    fs.writeFileSync(path.join(forged, 'bwrap-runtime-ready'), 'ready\n');
    fs.chmodSync(forged, 0o700);
    const forgedRun = run('bash', [bootstrap, '--continue', root, forged], {
      env: { ...process.env, AISTICK_USERNS_GUARD_PID: String(process.pid) },
    });
    assert.notEqual(forgedRun.status, 0, 'a fully staged, correctly named private workspace cannot forge a guard handoff');
    assert.match(forgedRun.stderr, /live guard command line/);
    assert.equal(fs.readFileSync(path.join(root, 'npm-global', 'linux-x64', 'active.json'), 'utf8'), before,
      'rejected continuations do not touch the active pointer');
    assertPreparedUnchanged('rejected handoffs');

    // A synthetic module launches the real continuation with the exact CLI
    // argv and PID handoff, then exits before any package or network work.
    const handoffWork = path.join(temp, 'aistick-linux-bootstrap.handoff');
    const handoffRoot = path.join(temp, 'handoff-root');
    const handoffScripts = path.join(temp, 'handoff-scripts');
    fs.mkdirSync(path.join(handoffWork, 'node', 'bin'), { recursive: true, mode: 0o700 });
    fs.mkdirSync(path.join(handoffWork, 'bwrap', 'root', 'usr', 'bin'), { recursive: true, mode: 0o700 });
    fs.chmodSync(handoffWork, 0o700);
    fs.copyFileSync(process.execPath, path.join(handoffWork, 'node', 'bin', 'node'));
    fs.chmodSync(path.join(handoffWork, 'node', 'bin', 'node'), 0o700);
    fs.writeFileSync(path.join(handoffWork, 'bwrap', 'root', 'usr', 'bin', 'bwrap'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    fs.writeFileSync(path.join(handoffWork, 'bwrap-runtime-ready'), 'ready\n');
    fs.mkdirSync(handoffRoot, { mode: 0o700 });
    fs.mkdirSync(handoffScripts, { mode: 0o700 });
    const handoffBootstrap = path.join(handoffScripts, 'bootstrap-linux.sh');
    const handoffModule = path.join(handoffScripts, 'linux-userns.cjs');
    const handoffHit = path.join(temp, 'handoff-hit');
    const handoffParent = path.join(temp, 'handoff-parent');
    const continueClose = 'fi\nmkdir -p "$WORK/download-home"';
    assert.ok(source.includes(continueClose), 'continuation handoff exit insertion point exists');
    fs.writeFileSync(handoffBootstrap, source.replace(continueClose,
      `fi\nif [[ $MODE == continue ]]; then printf '%s\\n' "$AISTICK_USERNS_GUARD_PID" > ${JSON.stringify(handoffHit)}; exit 0; fi\nmkdir -p "$WORK/download-home"`));
    fs.writeFileSync(handoffModule, `const fs=require('node:fs');const {spawnSync}=require('node:child_process');const i=process.argv.indexOf('--');if(i<0)process.exit(2);fs.writeFileSync(process.env.TEST_GUARD_PARENT,String(process.pid));const r=spawnSync(process.argv[i+1],process.argv.slice(i+2),{stdio:'inherit',env:{...process.env,AISTICK_USERNS_GUARD_PID:String(process.pid)}});process.exit(r.status??1);\n`);
    const runtimeJson = JSON.stringify({ sessionRoot: handoffWork, runtimeRoot: handoffWork, sandboxRoot: path.join(handoffWork, 'bwrap'), bwrap: path.join(handoffWork, 'bwrap/root/usr/bin/bwrap') });
    const handoff = run(path.join(handoffWork, 'node', 'bin', 'node'), [handoffModule, '--guard-command', runtimeJson, '--', 'bash', handoffBootstrap, '--continue', handoffRoot, handoffWork], {
      env: { ...process.env, TEST_GUARD_PARENT: handoffParent },
    });
    assertOk(handoff, 'a live exact guard handoff reaches continuation validation');
    assert.equal(fs.readFileSync(handoffHit, 'utf8').trim(), fs.readFileSync(handoffParent, 'utf8'),
      'continuation accepts only its live direct guard PID');

    // Exercise the actual parent gate, signal handler, and cleanup with a fake
    // guard. No sudo or network operation is made.
    const gateStart = source.indexOf('if [[ $MODE == prepare ]]; then\n  # The guard keeps');
    const gateEnd = source.indexOf('\nfi\n\nNODE=', gateStart);
    assert.ok(gateStart >= 0 && gateEnd > gateStart, 'guard gate block found');
    let gate = source.slice(gateStart, gateEnd + 4).replace(/exit "\$GUARD_STATUS"/, 'return "$GUARD_STATUS"');
    const cleanup = source.match(/cleanup\(\) \{[\s\S]*?\n\}/)?.[0];
    const signalHandler = source.match(/handle_guard_signal\(\) \{[\s\S]*?\n\}/)?.[0];
    assert.ok(cleanup && signalHandler, 'production guard cleanup and signal handlers found');
    const fakeNode = path.join(work, 'node', 'bin', 'node');
    fs.mkdirSync(path.dirname(fakeNode), { recursive: true });
    const fakeLog = path.join(temp, 'guard.json');
    const runtimeLog = path.join(temp, 'runtime.json');
    const childLog = path.join(temp, 'child.json');
    const guardStarted = path.join(temp, 'guard-started');
    const guardFinished = path.join(temp, 'guard-finished');
    const fakeNodeText = `#!/usr/bin/env bash
set -eu
if [[ $1 == -e ]]; then
  printf '{"sessionRoot":"%s","runtimeRoot":"%s","sandboxRoot":"%s","bwrap":"%s"}' "$3" "$3" "$4" "$5"
  exit 0
fi
if [[ \${FAKE_REQUIRE_TTY:-0} == 1 && ! -t 0 ]]; then echo 'guard stdin lost its TTY' >&2; exit 92; fi
printf '%s\\n' "$*" > ${JSON.stringify(fakeLog)}
printf '%s\\n' "$3" > ${JSON.stringify(runtimeLog)}
if [[ \${FAKE_GUARD_MODE:-normal} == signal ]]; then
  trap 'sleep 0.25; printf done > ${JSON.stringify(guardFinished)}; exit 0' INT TERM HUP
  : > ${JSON.stringify(guardStarted)}
  kill -TERM "$PPID"
  while :; do sleep 0.1; done
fi
printf '{"euid":"%s","bwrap":"%s","ldLibraryPath":"%s"}\\n' "$(id -u)" "$BWRAP_PATH" "$LD_LIBRARY_PATH" > ${JSON.stringify(childLog)}
exit "\${FAKE_GUARD_STATUS:-0}"
`;
    fs.writeFileSync(fakeNode, fakeNodeText, { mode: 0o700 });
    fs.chmodSync(fakeNode, 0o700);

    function invokeGate(status, mode = 'normal', pty = false) {
      fs.mkdirSync(path.join(work, 'bwrap', 'sandbox', 'lib', 'x86_64-linux-gnu'), { recursive: true });
      fs.mkdirSync(path.join(work, 'bwrap', 'sandbox', 'lib64'), { recursive: true });
      const harness = `WORK=${JSON.stringify(work)}
ROOT=${JSON.stringify(root)}
SCRIPT_DIR=${JSON.stringify(scripts)}
MODE=prepare
FAKE_GUARD_STATUS=${status}
FAKE_GUARD_MODE=${mode}
FAKE_REQUIRE_TTY=${pty ? 1 : 0}
BWRAP_PATH=${JSON.stringify(path.join(work, 'bwrap/root/usr/bin/bwrap'))}
LD_LIBRARY_PATH=${JSON.stringify(sandboxExecEnv(work, path.join(work, 'bwrap')).LD_LIBRARY_PATH)}
export FAKE_GUARD_STATUS FAKE_GUARD_MODE FAKE_REQUIRE_TTY BWRAP_PATH LD_LIBRARY_PATH
GUARD_PID=
${cleanup}
${signalHandler}
trap cleanup EXIT
trap 'handle_guard_signal INT' INT
trap 'handle_guard_signal TERM' TERM
trap 'handle_guard_signal HUP' HUP
gate() { ${gate.replaceAll('\n', '\n  ')}
}
gate
`;
      if (pty) return run('script', ['-q', '-e', '-c', `bash -c ${shellQuote(harness)}`, '/dev/null']);
      return run('bash', ['-c', harness]);
    }

    let outcome = invokeGate(78);
    assert.equal(outcome.status, 78, `consent cancellation propagates its failure status: ${outcome.stderr}`);
    assert.match(outcome.stderr, /preparation stopped/);
    assert.equal(fs.existsSync(work), false, 'parent cleanup runs after cancelled guard teardown');
    assert.equal(fs.readFileSync(path.join(root, 'npm-global', 'linux-x64', 'active.json'), 'utf8'), before,
      'cancelled guard does not switch the active package pointer');
    assertPreparedUnchanged('cancelled guard');

    fs.mkdirSync(work, { mode: 0o700 });
    fs.chmodSync(work, 0o700);
    fs.mkdirSync(path.dirname(fakeNode), { recursive: true });
    fs.writeFileSync(fakeNode, fakeNodeText, { mode: 0o700 });
    fs.chmodSync(fakeNode, 0o700);
    outcome = invokeGate(0, 'normal', true);
    assert.equal(outcome.status, 0, `approved fake continuation returns successfully with a TTY: ${outcome.stderr}`);
    const args = fs.readFileSync(fakeLog, 'utf8');
    assert.match(args, /--guard-command/);
    assert.match(args, /--continue/);
    const runtime = JSON.parse(fs.readFileSync(runtimeLog, 'utf8'));
    assert.equal(runtime.bwrap, path.join(work, 'bwrap/root/usr/bin/bwrap'), 'guard and continuation share the exact prepared bwrap executable');
    assert.equal(runtime.runtimeRoot, work);
    assert.equal(runtime.sandboxRoot, path.join(work, 'bwrap'));
    const child = JSON.parse(fs.readFileSync(childLog, 'utf8'));
    assert.notEqual(child.euid, '0', 'the approved continuation remains unprivileged');
    assert.equal(child.bwrap, path.join(work, 'bwrap/root/usr/bin/bwrap'), 'guard uses the same prepared bwrap executable');
    assert.equal(child.ldLibraryPath, expectedLoaderPath,
      'continuation sees only the prepared private loader paths');
    assert.equal(fs.existsSync(work), false, 'parent removes WORK after successful guard teardown');
    assert.equal(fs.readFileSync(path.join(root, 'npm-global', 'linux-x64', 'active.json'), 'utf8'), before,
      'synthetic continuation does not alter the active pointer');
    assertPreparedUnchanged('approved synthetic guard');

    fs.mkdirSync(work, { mode: 0o700 });
    fs.chmodSync(work, 0o700);
    fs.mkdirSync(path.dirname(fakeNode), { recursive: true });
    fs.writeFileSync(fakeNode, fakeNodeText, { mode: 0o700 });
    fs.chmodSync(fakeNode, 0o700);
    outcome = invokeGate(0, 'signal');
    assert.equal(outcome.status, 143, `parent exits on TERM after guard completion: ${outcome.stderr}`);
    assert.ok(fs.existsSync(guardStarted), 'living fake guard started before parent signal');
    assert.equal(fs.readFileSync(guardFinished, 'utf8'), 'done', 'parent waited for fake guard cleanup before exiting');
    assert.equal(fs.existsSync(work), false, 'WORK is removed after the signaled guard has finished');
    assert.equal(fs.readFileSync(path.join(root, 'npm-global', 'linux-x64', 'active.json'), 'utf8'), before,
      'signaled guard does not switch the active package pointer');
    assertPreparedUnchanged('signaled guard');

    const retainedWork = path.join(temp, 'aistick-linux-bootstrap.marker');
    fs.mkdirSync(retainedWork, { mode: 0o700 });
    fs.chmodSync(retainedWork, 0o700);
    fs.writeFileSync(path.join(retainedWork, '.apparmor-cleanup-unconfirmed'), 'unconfirmed\n', { mode: 0o600 });
    const retention = run('bash', ['-c', `WORK=${JSON.stringify(retainedWork)}\nGUARD_PID=\n${cleanup}\ncleanup`]);
    assert.equal(retention.status, 0, `cleanup retains a workspace when AppArmor unload is unconfirmed: ${retention.stderr}`);
    assert.ok(retention.stderr.includes(retainedWork), 'retention diagnostic identifies the exact private workspace path');
    assert.equal(fs.existsSync(retainedWork), true, 'cleanup preserves the workspace while the kernel exception may remain active');
    assert.equal(fs.statSync(retainedWork).mode & 0o777, 0o700, 'retained workspace remains private');
    assert.equal(fs.existsSync(path.join(retainedWork, '.apparmor-cleanup-unconfirmed')), true,
      'cleanup marker remains available for recovery');
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }

  console.log('Linux bootstrap AppArmor/userns gate tests passed.');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
