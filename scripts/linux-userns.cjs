'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { sandboxExecEnv } = require('./linux-sandbox.cjs');

const CONSENT_TOKEN = 'APPARMOR';
const AUTHENTICATED = 'PORTABLE_APPARMOR_AUTHENTICATED\n';
const LOADED = 'PORTABLE_APPARMOR_LOADED\n';
const READY = 'PORTABLE_APPARMOR_READY\n';
const UNLOADED = 'PORTABLE_APPARMOR_UNLOADED\n';
const CLEANUP_UNCONFIRMED_MARKER = '.apparmor-cleanup-unconfirmed';
const CLEANUP_UNCONFIRMED_TEXT = 'AppArmor profile cleanup could not be confirmed.\n';
const STATIC_HELPER = String.raw`set -eu
LC_ALL=C
export LC_ALL
parser=$1
name=$2
attachment=$3
session=$4
case "$parser" in /usr/sbin/apparmor_parser|/sbin/apparmor_parser) ;; *) exit 81 ;; esac
[ "$(id -u)" = 0 ] || exit 84
[ -n "$SUDO_UID" ] || exit 84
case "$SUDO_UID" in *[!0-9]*) exit 84 ;; esac
case "$name" in "portable-ai-bwrap-$SUDO_UID-"????????????) ;; *) exit 82 ;; esac
suffix=${'${name##*-}'}
case "$suffix" in *[!0-9a-f]*|'') exit 82 ;; esac
case "$attachment" in /*) ;; *) exit 83 ;; esac
case "$attachment$session" in *[!A-Za-z0-9_./-]*) exit 83 ;; esac
case "$attachment" in "$session"/*) ;; *) exit 83 ;; esac
[ "$(readlink -f -- "$parser")" = "$parser" ] || exit 84
[ "$(stat -c '%u' -- "$parser")" = 0 ] || exit 84
[ "$(stat -c '%F' -- "$parser")" = 'regular file' ] || exit 84
mode=$(stat -c '%a' -- "$parser")
[ "$((0$mode & 0022))" -eq 0 ] || exit 84
[ -x "$parser" ] || exit 84
printf '%s' 'PORTABLE_APPARMOR_AUTHENTICATED
'
[ "$(readlink -f -- "$attachment")" = "$attachment" ] || exit 85
check_path=$attachment
while [ "$check_path" != "$session" ]; do
  [ ! -L "$check_path" ] || exit 85
  check_path=$(dirname -- "$check_path")
  [ "$(stat -c '%u' -- "$check_path")" = "$SUDO_UID" ] || exit 86
  [ "$(stat -c '%F' -- "$check_path")" = directory ] || exit 86
  mode=$(stat -c '%a' -- "$check_path")
  [ "$((0$mode & 0022))" -eq 0 ] || exit 86
done
[ ! -L "$session" ] || exit 85
item=$(stat -c '%u:%a:%F' -- "$session")
[ "$item" = "$SUDO_UID:700:directory" ] || exit 86
[ "$(stat -c '%u' -- "$attachment")" = "$SUDO_UID" ] || exit 87
[ "$(stat -c '%F' -- "$attachment")" = 'regular file' ] || exit 87
mode=$(stat -c '%a' -- "$attachment")
[ "$((0$mode & 06000))" -eq 0 ] || exit 87
[ -x "$attachment" ] || exit 87
profile_text() {
  printf 'abi <abi/4.0>,\nprofile %s "%s" flags=(unconfined) {\n  userns,\n}\n' "$name" "$attachment"
}
if ! profile_text | "$parser" -K -a; then exit 88; fi
cleanup() {
  trap - EXIT
  if ! profile_text | "$parser" -K -R >/dev/null 2>&1; then exit 89; fi
  printf '%s' 'PORTABLE_APPARMOR_UNLOADED
'
  exit 0
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' 'PORTABLE_APPARMOR_LOADED
'
printf '%s' 'PORTABLE_APPARMOR_READY
'
cat >/dev/null
`;

function parserPath() {
  for (const candidate of ['/usr/sbin/apparmor_parser', '/sbin/apparmor_parser']) {
    try {
      const st = fs.lstatSync(candidate);
      if (st.isFile() && !st.isSymbolicLink() && (st.mode & 0o111)) return candidate;
    } catch {}
  }
  return null;
}

function cleanupMarkerPath(sessionRoot) { return path.join(sessionRoot, CLEANUP_UNCONFIRMED_MARKER); }

function writeCleanupUnconfirmedMarker(sessionRoot) {
  const root = path.resolve(sessionRoot);
  const rootStat = fs.lstatSync(root);
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory() || rootStat.uid !== process.getuid?.() || (rootStat.mode & 0o777) !== 0o700) {
    throw new Error('cannot record uncertain AppArmor cleanup outside the owned private session root');
  }
  const marker = cleanupMarkerPath(root);
  if (!fs.constants.O_NOFOLLOW) throw new Error('this platform cannot safely create the AppArmor cleanup marker');
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW;
  let fd;
  try {
    fd = fs.openSync(marker, flags, 0o600);
    fs.fchmodSync(fd, 0o600);
    fs.writeFileSync(fd, CLEANUP_UNCONFIRMED_TEXT, 'utf8');
    fs.fsyncSync(fd);
  } catch (error) {
    if (error.code === 'EEXIST') {
      const st = fs.lstatSync(marker);
      if (st.isSymbolicLink() || !st.isFile() || st.uid !== process.getuid?.() || (st.mode & 0o777) !== 0o600 || fs.readFileSync(marker, 'utf8') !== CLEANUP_UNCONFIRMED_TEXT) {
        throw new Error('an unsafe or unexpected AppArmor cleanup marker already exists');
      }
      return marker;
    }
    throw error;
  } finally { if (fd !== undefined) fs.closeSync(fd); }
  return marker;
}

function clearCleanupUnconfirmedMarker(sessionRoot) {
  const marker = cleanupMarkerPath(path.resolve(sessionRoot));
  let st;
  try { st = fs.lstatSync(marker); } catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (st.isSymbolicLink() || !st.isFile() || st.uid !== process.getuid?.() || (st.mode & 0o777) !== 0o600 || fs.readFileSync(marker, 'utf8') !== CLEANUP_UNCONFIRMED_TEXT) {
    throw new Error('refusing to remove an unsafe or unexpected AppArmor cleanup marker');
  }
  fs.unlinkSync(marker);
}

function authorizedCleanupError(error, authorization) {
  const wrapped = new Error(error.message, { cause: error });
  wrapped.usernsAuthorization = authorization;
  return wrapped;
}

function usernsRestriction(files) {
  const file = files || '/proc/sys/kernel/apparmor_restrict_unprivileged_userns';
  try {
    const value = fs.readFileSync(file, 'utf8').trim();
    return value === '0' ? 0 : value === '1' ? 1 : null;
  } catch { return null; }
}

function usernsGlobalBlock(files = ['/proc/sys/kernel/unprivileged_userns_clone', '/proc/sys/user/max_user_namespaces']) {
  for (const file of files) {
    try {
      const value = fs.readFileSync(file, 'utf8').trim();
      if (/^\d+$/.test(value) && Number(value) === 0) return file;
    } catch {}
  }
  return null;
}

function validateRuntime(runtime) {
  if (!runtime || typeof runtime !== 'object') throw new Error('sandbox runtime is required');
  const sessionRoot = path.resolve(runtime.sessionRoot || '');
  const bwrap = path.resolve(runtime.bwrap || '');
  if (!path.isAbsolute(runtime.sessionRoot || '') || !path.isAbsolute(runtime.bwrap || '')) throw new Error('sandbox runtime paths must be absolute');
  if (!/^[A-Za-z0-9_./-]+$/.test(sessionRoot)) throw new Error('session root contains unsupported characters');
  const statNoLinks = p => {
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) throw new Error('AppArmor runtime paths cannot contain symbolic links');
    return st;
  };
  let cursor = sessionRoot;
  const ancestry = [];
  while (true) { ancestry.push(cursor); const parent = path.dirname(cursor); if (parent === cursor) break; cursor = parent; }
  for (const entry of ancestry) statNoLinks(entry);
  const session = statNoLinks(sessionRoot);
  if (!session.isDirectory() || (session.mode & 0o777) !== 0o700 || session.uid !== process.getuid?.()) throw new Error('session root must be owned by this user and private mode 700');
  for (const key of ['runtimeRoot', 'sandboxRoot']) {
    if (runtime[key] === undefined) continue;
    const root = path.resolve(runtime[key]);
    const relRoot = path.relative(sessionRoot, root);
    if (!path.isAbsolute(runtime[key]) || relRoot === '..' || relRoot.startsWith(`..${path.sep}`) || path.isAbsolute(relRoot)) throw new Error(`${key} must remain inside the private session tree`);
    let itemPath = sessionRoot;
    for (const part of relRoot.split(path.sep).filter(Boolean)) {
      itemPath = path.join(itemPath, part);
      const st = statNoLinks(itemPath);
      if (!st.isDirectory() || st.uid !== process.getuid?.() || (st.mode & 0o022)) throw new Error(`${key} ancestry must be owned and not group or world writable`);
    }
  }
  const rel = path.relative(sessionRoot, bwrap);
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) throw new Error('bubblewrap must remain inside the private session tree');
  cursor = sessionRoot;
  for (const part of rel.split(path.sep).slice(0, -1)) {
    cursor = path.join(cursor, part);
    const st = statNoLinks(cursor);
    if (!st.isDirectory() || (st.mode & 0o022) || st.uid !== process.getuid?.()) throw new Error('bubblewrap parent directories must be owned and not group or world writable');
  }
  const bin = statNoLinks(bwrap);
  if (!bin.isFile() || !(bin.mode & 0o111) || bin.uid !== process.getuid?.() || (bin.mode & 0o6000)) throw new Error('bubblewrap must be an owned regular executable without setuid or setgid bits');
  if (fs.realpathSync(bwrap) !== bwrap) throw new Error('bubblewrap path must be canonical');
  return { ...runtime, sessionRoot, bwrap };
}

function sandboxProfileText(runtime) {
  const rt = validateRuntime(runtime);
  if (!/^[A-Za-z0-9_./-]+$/.test(rt.bwrap)) throw new Error('bubblewrap path contains unsupported characters');
  const uid = process.getuid?.();
  if (!Number.isInteger(uid)) throw new Error('cannot determine current user id');
  const hash = crypto.createHash('sha256').update(rt.bwrap).digest('hex').slice(0, 12);
  const name = `portable-ai-bwrap-${uid}-${hash}`;
  const text = `abi <abi/4.0>,\nprofile ${name} "${rt.bwrap}" flags=(unconfined) {\n  userns,\n}\n`;
  return { name, attachment: rt.bwrap, text };
}

function manualUnload(profile, parser) {
  return `sudo ${parser} -K -R <<'PORTABLE_APPARMOR_PROFILE'\n${profile.text}PORTABLE_APPARMOR_PROFILE\n`;
}

function manualLoad(profile, parser) {
  return `sudo ${parser} -K -a <<'PORTABLE_APPARMOR_PROFILE'\n${profile.text}PORTABLE_APPARMOR_PROFILE\n`;
}

function runProbe(runtime, hooks = {}) {
  const rt = validateRuntime(runtime);
  const execEnv = sandboxExecEnv(path.resolve(rt.runtimeRoot), rt.sandboxRoot && path.resolve(rt.sandboxRoot));
  const run = hooks.spawnSync || spawnSync;
  let result;
  try {
    result = run(rt.bwrap, ['--unshare-user', '--uid', '0', '--gid', '0', '--ro-bind', '/', '/', '/usr/bin/true'], {
      cwd: path.dirname(rt.bwrap), env: execEnv, encoding: 'utf8', timeout: 5000, windowsHide: true,
    });
  } catch (error) { return { ok: false, kind: 'exec-error', error, stdout: '', stderr: '' }; }
  if (!result.error && result.status === 0) return { ok: true, kind: 'ok', stdout: result.stdout || '', stderr: result.stderr || '' };
  if (result.error?.code === 'ETIMEDOUT' || result.signal === 'SIGTERM' && result.error) return { ok: false, kind: 'timeout', error: result.error, stdout: result.stdout || '', stderr: result.stderr || '' };
  const text = `${result.stderr || ''}\n${result.stdout || ''}`;
  if (result.error?.code === 'ENOENT' || /shared librar|error while loading|cannot open shared object/i.test(text)) return { ok: false, kind: 'loader', error: result.error, stdout: result.stdout || '', stderr: result.stderr || '' };
  if (/apparmor|operation not permitted|permission denied|unprivileged user namespace|user namespace/i.test(text)) return { ok: false, kind: 'namespace-permission', status: result.status, stdout: result.stdout || '', stderr: result.stderr || '' };
  return { ok: false, kind: 'other', status: result.status, error: result.error, stdout: result.stdout || '', stderr: result.stderr || '' };
}

function probeUserns(runtime, hooks) { return runProbe(runtime, hooks); }

function runParser(parser, args, text, hooks = {}) {
  const run = hooks.spawnSync || spawnSync;
  const result = run(parser, args, { input: text, encoding: 'utf8', timeout: 10000, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error(`AppArmor profile syntax check failed${result.stderr ? `: ${String(result.stderr).slice(0, 500)}` : ''}`);
  return result;
}

function sudoCommand(profile, runtime, parser, hooks = {}) {
  const launch = hooks.spawn || spawn;
  const sudo = '/usr/bin/sudo';
  const sudoStat = hooks.sudoStat ? hooks.sudoStat(sudo) : fs.lstatSync(sudo);
  if (!sudoStat.isFile() || sudoStat.isSymbolicLink() || sudoStat.uid !== 0 || (sudoStat.mode & 0o022) || !(sudoStat.mode & 0o111)) throw new Error('the trusted sudo executable is unavailable or not protected');
  const child = launch(sudo, ['--', '/bin/sh', '-c', STATIC_HELPER, 'portable-ai-apparmor', parser, profile.name, profile.attachment, runtime.sessionRoot], {
    cwd: runtime.sessionRoot, env: { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', LC_ALL: 'C' },
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  return child;
}

async function ensureSandboxUserns(runtime, options = {}) {
  const rt = validateRuntime(runtime);
  const probe = (options.probe || probeUserns)(rt, options.hooks || {});
  if (probe.ok) return { fixed: false, authorization: null };
  if (probe.kind !== 'namespace-permission') throw new Error(`sandbox user namespace probe failed (${probe.kind}): ${String(probe.stderr || probe.error?.message || '').slice(0, 500)}`);
  const globalBlock = (options.globalBlock || usernsGlobalBlock)();
  if (globalBlock) throw new Error(`sandbox user namespaces are disabled by ${globalBlock}; AppArmor profile assistance cannot override that system setting`);
  const restriction = (options.restriction || usernsRestriction)();
  if (restriction !== 1) throw new Error(`sandbox user namespace access is denied, but the AppArmor userns restriction is not confirmed (value: ${restriction})`);
  const parser = options.parser || parserPath();
  if (!parser || !['/usr/sbin/apparmor_parser', '/sbin/apparmor_parser'].includes(parser)) throw new Error('the trusted AppArmor parser is unavailable');
  const parserStat = options.hooks?.parserStat ? options.hooks.parserStat(parser) : fs.lstatSync(parser);
  if (!parserStat.isFile() || parserStat.isSymbolicLink() || parserStat.uid !== 0 || (parserStat.mode & 0o022)) throw new Error('the trusted AppArmor parser is not a root-owned protected regular file');
  const profile = sandboxProfileText(rt);
  runParser(parser, ['-Q', '-K'], profile.text, options.hooks || {});
  const isTTY = options.isTTY ?? Boolean(process.stdin.isTTY && process.stderr.isTTY);
  if (!isTTY) throw new Error(`AppArmor userns access needs one-time authorization in a TTY. Manual profile load command:\n${manualLoad(profile, parser)}Manual unload command (use the same profile text):\n${manualUnload(profile, parser)}`);
  const ask = options.ask || (async prompt => new Promise(resolve => {
    const readline = require('node:readline');
    const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
    rl.question(prompt, answer => { rl.close(); resolve(answer); });
  }));
  const answer = await ask(`AppArmor 阻止了本次 user namespace。临时规则只作用于当前会话使用的这一个 bubblewrap 文件；sudo 会在本地终端请求管理员密码。输入 ${CONSENT_TOKEN} 允许，其他输入取消：`);
  if (answer !== CONSENT_TOKEN) throw new Error('AppArmor authorization was declined; sandbox startup stopped.');
  const child = sudoCommand(profile, rt, parser, options.hooks || {});
  let stdout = ''; let stderr = '';
  child.stdout?.on('data', chunk => { stdout = (stdout + chunk.toString()).slice(-256); });
  child.stderr?.on('data', chunk => { const value = chunk.toString(); stderr = (stderr + value).slice(-1024); process.stderr.write(value); });
  const authorization = { child, profile, parser, sessionRoot: rt.sessionRoot, released: false, releasePromise: null, stderr: () => stderr, closed: false, authenticated: false, loaded: false, unloaded: false, inputClosed: false };
  let ready;
  try { ready = await new Promise((resolve, reject) => {
    let done = false; let timer;
    const finish = (error, value) => { if (done) return; done = true; clearTimeout(timer); error ? reject(error) : resolve(value); };
    const scan = () => {
      if (stdout.includes(AUTHENTICATED) && !timer) timer = setTimeout(() => finish(new Error('temporary AppArmor profile helper timed out after authorization')), options.helperTimeout || 15000);
      if (stdout.includes(AUTHENTICATED)) authorization.authenticated = true;
      if (stdout.includes(LOADED)) authorization.loaded = true;
      if (stdout.includes(UNLOADED)) authorization.unloaded = true;
      if (stdout.includes(READY)) finish(null, true);
      else if (stdout.length > 128) finish(new Error('AppArmor helper returned unexpected output'));
    };
    child.stdout?.on('data', scan);
    child.once('error', finish);
    child.once('exit', (code, signal) => finish(new Error(`AppArmor helper exited before readiness (${code ?? signal}): ${stderr.slice(0, 300)}`)));
    child.once('close', () => { authorization.closed = true; });
  }); } catch (error) {
    try { await releaseSandboxUserns(authorization, options); }
    catch (cleanupError) { throw authorizedCleanupError(new Error(`${error.message}; ${cleanupError.message}`), authorization); }
    throw error;
  }
  if (!ready) throw new Error('temporary AppArmor profile did not become ready');
  let after;
  try { after = (options.probe || probeUserns)(rt, options.hooks || {}); }
  catch (error) {
    try { await releaseSandboxUserns(authorization, options); }
    catch (cleanupError) { throw authorizedCleanupError(new Error(`${error.message}; ${cleanupError.message}`), authorization); }
    throw error;
  }
  if (!after.ok) {
    await releaseSandboxUserns(authorization, options);
    throw new Error(`user namespace probe still fails after AppArmor authorization (${after.kind}): ${String(after.stderr || '').slice(0, 400)}`);
  }
  return { fixed: true, authorization };
}

function releaseSandboxUserns(authorization, options = {}) {
  if (!authorization) return Promise.resolve();
  if (authorization.releasePromise) return authorization.releasePromise;
  authorization.released = true;
  const releasePromise = new Promise((resolve, reject) => {
    const child = authorization.child;
    if (!child) return resolve();
    if (authorization.closed || child.exitCode !== null || child.signalCode !== null) {
      if (child.exitCode === 0 || (authorization.unloaded && child.exitCode !== 89)) return resolve();
      if (child.exitCode === 89) return reject(new Error(`temporary AppArmor profile unload could not be confirmed; run:\n${manualUnload(authorization.profile, authorization.parser)}`));
      if (!authorization.loaded && !authorization.authenticated && !child.signalCode) return resolve();
      if (!authorization.loaded && !child.signalCode && child.exitCode >= 81 && child.exitCode <= 88) return resolve();
      return reject(new Error(`temporary AppArmor profile unload could not be confirmed; run:\n${manualUnload(authorization.profile, authorization.parser)}`));
    }
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error(`temporary AppArmor profile unload could not be confirmed; run:\n${manualUnload(authorization.profile, authorization.parser)}`));
    }, options.releaseTimeout || 5000);
    const finish = (error) => { if (settled) return; settled = true; clearTimeout(timer); error ? reject(error) : resolve(); };
    child.once('close', code => {
      authorization.closed = true;
      if (code === 0 || (code !== 89 && authorization.unloaded) || (code !== 89 && !authorization.loaded && !authorization.authenticated && code !== null)) finish();
      else if (code === 89) finish(new Error(`temporary AppArmor profile helper failed during unload; run:\n${manualUnload(authorization.profile, authorization.parser)}`));
      else if (!authorization.loaded && !child.signalCode && code >= 81 && code <= 88) finish();
      else finish(new Error(`temporary AppArmor profile helper failed during unload; run:\n${manualUnload(authorization.profile, authorization.parser)}`));
    });
    child.once('error', error => { authorization.spawnError = error; if (!authorization.loaded) finish(); });
    if (!authorization.inputClosed) {
      authorization.inputClosed = true;
      child.stdin?.end();
    }
  });
  const trackedRelease = releasePromise.then(() => {
    try {
      if (authorization.sessionRoot) clearCleanupUnconfirmedMarker(authorization.sessionRoot);
    } catch (error) { error.usernsAuthorization = authorization; throw error; }
  }, error => {
    let reported = error;
    try {
      if (authorization.sessionRoot) writeCleanupUnconfirmedMarker(authorization.sessionRoot);
    } catch (markerError) { reported = new Error(`${error.message}; could not record cleanup uncertainty: ${markerError.message}`, { cause: error }); }
    reported.usernsAuthorization = authorization;
    throw reported;
  });
  authorization.releasePromise = trackedRelease;
  trackedRelease.catch(() => { if (!authorization.closed) authorization.releasePromise = null; });
  return trackedRelease;
}

async function guardCommand(runtime, command, args) {
  const result = await ensureSandboxUserns(runtime);
  const releaseSignals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  let child;
  let childError = null;
  let code = 1;
  const handlers = new Map(releaseSignals.map(signal => [signal, () => { if (child && !child.killed) child.kill(signal); }]));
  for (const [signal, handler] of handlers) process.on(signal, handler);
  const cleanup = () => { for (const [signal, handler] of handlers) process.off(signal, handler); };
  try {
    child = spawn(command, args, { stdio: 'inherit', env: { ...process.env, AISTICK_USERNS_GUARD_PID: String(process.pid) }, detached: false });
    code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', (c, signal) => resolve(signal ? 128 + (os.constants.signals[signal] || 1) : c ?? 1));
    });
  } catch (error) { childError = error; }
  try { await releaseSandboxUserns(result.authorization); }
  catch (releaseError) {
    cleanup();
    if (childError) throw new Error(`${childError.message}; ${releaseError.message}`);
    throw releaseError;
  }
  cleanup();
  if (childError) throw childError;
  process.exitCode = code;
}

module.exports = { CONSENT_TOKEN, AUTHENTICATED, LOADED, READY, UNLOADED, CLEANUP_UNCONFIRMED_MARKER, STATIC_HELPER, parserPath, usernsRestriction, usernsGlobalBlock, sandboxProfileText, manualLoad, manualUnload, writeCleanupUnconfirmedMarker, clearCleanupUnconfirmedMarker, probeUserns, ensureSandboxUserns, releaseSandboxUserns };

if (require.main === module && process.argv[2] === '--guard-command') {
  let i = 3;
  try {
    const runtime = JSON.parse(process.argv[i++]);
    if (process.argv[i++] !== '--' || !process.argv[i]) throw new Error('usage: linux-userns.cjs --guard-command <runtime-json> -- command [args...]');
    const command = process.argv[i++];
    guardCommand(runtime, command, process.argv.slice(i)).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
  } catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 2; }
}
