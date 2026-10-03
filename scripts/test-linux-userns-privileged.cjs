'use strict';

// Opt-in integration on an ephemeral GitHub Actions runner only. Never change
// sysctls, install packages, replace an existing profile, or use real configs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const userns = require('./linux-userns.cjs');

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 10000, ...options });
  if (result.error || result.status !== 0) throw new Error(`${executable} failed: ${result.error?.message || result.stderr || result.status}`);
  return result.stdout;
}
function skip(reason) { console.log(`SKIP real AppArmor policy lifecycle: ${reason}`); }
function kernelProfiles() {
  return run('/usr/bin/sudo', ['-n', '--', '/usr/bin/cat', '/sys/kernel/security/apparmor/profiles']);
}
function hasProfile(profiles, name) {
  return profiles.split('\n').some(line => line.startsWith(`${name} (`));
}
function waitForClose(child) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(child.exitCode);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('policy helper did not exit after its controller pipe closed')), 10000);
    const finish = (error, code) => { clearTimeout(timer); error ? reject(error) : resolve(code); };
    child.once('close', code => finish(null, code));
    child.once('error', error => finish(error));
  });
}

async function main() {
  if (process.platform !== 'linux' || !process.argv.includes('--allow-policy-test') || process.env.GITHUB_ACTIONS !== 'true' || process.env.RUNNER_ENVIRONMENT !== 'github-hosted') {
    return skip('requires Linux, --allow-policy-test, and an ephemeral GitHub Actions runner');
  }
  let enabled = '';
  try { enabled = fs.readFileSync('/sys/module/apparmor/parameters/enabled', 'utf8').trim(); } catch {}
  if (enabled !== 'Y') return skip('the runner kernel has no active AppArmor');
  const parser = userns.parserPath();
  if (!parser) return skip('apparmor_parser is not installed on the runner');
  try {
    run('/usr/bin/sudo', ['-n', '--', '/usr/bin/true']);
    kernelProfiles();
  } catch { return skip('the runner does not expose policy status with passwordless sudo'); }
  if (userns.usernsGlobalBlock()) return skip('the runner globally disables user namespaces');

  const sessionRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-apparmor-ci-'));
  fs.chmodSync(sessionRoot, 0o700);
  let authorization = null;
  let mayRemoveDirectory = true;
  let profile;
  try {
    // apt download uses the runner's existing authenticated package indexes;
    // dpkg-deb only extracts into this private directory, never installs.
    run('/usr/bin/apt-get', ['download', 'bubblewrap'], {
      cwd: sessionRoot, timeout: 120000,
      env: { PATH: '/usr/bin:/bin', HOME: sessionRoot, LANG: 'C.UTF-8' },
    });
    const archives = fs.readdirSync(sessionRoot).filter(name => /^bubblewrap_[A-Za-z0-9.+:~_-]+_amd64\.deb$/.test(name));
    assert.equal(archives.length, 1, 'exactly one official amd64 bubblewrap package');
    const sandboxRoot = path.join(sessionRoot, 'bwrap');
    const extracted = path.join(sandboxRoot, 'root');
    fs.mkdirSync(extracted, { recursive: true, mode: 0o700 });
    run('/usr/bin/dpkg-deb', ['-x', path.join(sessionRoot, archives[0]), extracted]);
    const runtime = { sessionRoot, runtimeRoot: sessionRoot, sandboxRoot, bwrap: path.join(extracted, 'usr/bin/bwrap') };
    profile = userns.sandboxProfileText(runtime);
    assert.equal(hasProfile(kernelProfiles(), profile.name), false, 'test must never replace an existing profile');
    run(parser, ['-Q', '-K'], { input: profile.text });
    const before = userns.probeUserns(runtime);
    if (!before.ok && before.kind !== 'namespace-permission') throw new Error(`real bubblewrap preflight failed (${before.kind}): ${before.stderr}`);
    const naturalRestriction = !before.ok && userns.usernsRestriction() === 1;
    console.log(naturalRestriction
      ? 'Real runner AppArmor restriction: testing grant, real bwrap execution, and removal.'
      : 'Simulating only the initial AppArmor denial; policy load, bwrap execution, and removal are real.');

    function options() {
      let probes = 0;
      return {
        parser, isTTY: true, ask: async () => userns.CONSENT_TOKEN,
        restriction: () => 1,
        probe: rt => ++probes === 1
          ? { ok: false, kind: 'namespace-permission', status: 1, stderr: 'synthetic initial permission denial for policy lifecycle integration' }
          : userns.probeUserns(rt),
        hooks: { spawn: (executable, args, config) => {
          assert.equal(executable, '/usr/bin/sudo');
          return spawn(executable, ['-n', ...args], config);
        } },
      };
    }
    authorization = (await userns.ensureSandboxUserns(runtime, options())).authorization;
    assert.ok(authorization, 'helper should hold the temporary policy authorization');
    assert.equal(hasProfile(kernelProfiles(), profile.name), true, 'exact-path profile must be present in the real kernel');
    assert.equal(userns.probeUserns(runtime).ok, true, 'real bubblewrap must execute after the profile grant');
    if (naturalRestriction) {
      const other = path.join(extracted, 'usr/bin/bwrap-unapproved');
      fs.copyFileSync(runtime.bwrap, other, fs.constants.COPYFILE_EXCL);
      const denied = userns.probeUserns({ ...runtime, bwrap: other });
      assert.equal(denied.ok, false, 'the temporary rule must not authorize another executable path');
      assert.equal(denied.kind, 'namespace-permission');
    }
    await assert.rejects(userns.ensureSandboxUserns(runtime, options()), /before readiness|profile/i,
      'a second helper must not replace or take ownership of an existing profile');
    assert.equal(hasProfile(kernelProfiles(), profile.name), true, 'rejected duplicate authorization must leave the original profile loaded');
    await userns.releaseSandboxUserns(authorization);
    authorization = null;
    assert.equal(hasProfile(kernelProfiles(), profile.name), false, 'normal release must unload the real profile');
    console.log('Real exact-path grant, duplicate rejection, and normal release passed.');

    authorization = (await userns.ensureSandboxUserns(runtime, options())).authorization;
    assert.equal(hasProfile(kernelProfiles(), profile.name), true);
    // EOF is also what the helper receives if its unprivileged controller dies.
    const closed = waitForClose(authorization.child);
    authorization.child.stdin.end();
    assert.equal(await closed, 0, 'controller pipe EOF must finish privileged cleanup');
    authorization = null;
    assert.equal(hasProfile(kernelProfiles(), profile.name), false, 'EOF must remove the real kernel profile');
    console.log('Real controller pipe EOF cleanup passed.');

    authorization = (await userns.ensureSandboxUserns(runtime, options())).authorization;
    const stopped = waitForClose(authorization.child);
    authorization.child.kill('SIGTERM');
    // The manager closes its controller pipe during signal shutdown. A POSIX
    // shell may defer its TERM trap until the foreground cat receives EOF.
    await userns.releaseSandboxUserns(authorization);
    await stopped;
    authorization = null;
    assert.equal(hasProfile(kernelProfiles(), profile.name), false, 'terminal/helper signals must remove the profile without a false cleanup failure');
    console.log('Real AppArmor policy load, duplicate rejection, bwrap execution, normal unload, controller EOF, and signal cleanup passed.');
  } finally {
    if (authorization) {
      try { await userns.releaseSandboxUserns(authorization); }
      catch (error) { mayRemoveDirectory = false; console.error(error.message); }
    }
    if (profile && hasProfile(kernelProfiles(), profile.name)) {
      mayRemoveDirectory = false;
      console.error(`Unconfirmed policy cleanup; retaining the private test directory: ${sessionRoot}`);
    }
    if (mayRemoveDirectory) fs.rmSync(sessionRoot, { recursive: true, force: true });
    else throw new Error('real AppArmor policy cleanup was not confirmed');
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
