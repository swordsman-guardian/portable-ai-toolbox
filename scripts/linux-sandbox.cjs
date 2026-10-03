'use strict';

const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const ENV_ALLOWLIST = new Set([
  'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_MODEL',
  'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_REASONING_MODEL',
]);

function assertPlainPath(p, label) {
  if (!path.isAbsolute(p)) throw new Error(`${label} must be an absolute path`);
  const full = path.resolve(p);
  let cursor = full;
  const chain = [];
  while (true) {
    chain.push(cursor);
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  for (const item of chain.reverse()) {
    const st = fs.lstatSync(item);
    if (st.isSymbolicLink()) throw new Error(`${label} crosses a symbolic link`);
  }
  return full;
}
function inside(root, p) {
  const rel = path.relative(root, p);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}
function assertSessionPath(sessionRoot, p, label) {
  p = assertPlainPath(p, label);
  if (!inside(sessionRoot, p)) throw new Error(`${label} must remain inside the private session tree`);
  return p;
}
function assertWorkDirectory(p) {
  p = path.resolve(p);
  if (!fs.lstatSync(p).isDirectory()) throw new Error('working directory must be an existing directory');
  let cursor = p;
  while (true) {
    if (fs.lstatSync(cursor).isSymbolicLink()) throw new Error('working directory ancestry crosses a symbolic link');
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  return p;
}
function prepareMinimalEtc(sessionRoot) {
  const dir = path.join(sessionRoot, 'tmp', 'sandbox-etc');
  assertSessionPath(sessionRoot, path.join(sessionRoot, 'tmp'), 'private sandbox temporary directory');
  if (!inside(sessionRoot, dir)) throw new Error('private sandbox system configuration escaped session root');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const nameservers = [];
  try {
    for (const line of fs.readFileSync('/etc/resolv.conf', 'utf8').split(/\r?\n/)) {
      const m = /^\s*nameserver\s+([0-9a-fA-F:.%]+)\s*$/.exec(line);
      if (m && !m[1].includes('%')) nameservers.push(m[1]);
    }
  } catch {}
  const files = {
    'passwd': 'root:x:0:0:Portable Session:/home/portable:/bin/sh\n',
    'group': 'root:x:0:\n',
    'nsswitch.conf': 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\nnetworks: files\nprotocols: files\nservices: files\n',
    'hosts': '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n',
    'resolv.conf': `${[...new Set(nameservers)].map(ip => `nameserver ${ip}\n`).join('') || 'nameserver 1.1.1.1\n'}options timeout:2 attempts:2\n`,
    'os-release': 'NAME="Portable Linux Session"\nID=portable\nPRETTY_NAME="Portable Linux Session"\n',
    'npm-user.npmrc': '', 'npm-global.npmrc': '',
  };
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(dir, name);
    try {
      const st = fs.lstatSync(file);
      if (!st.isFile() || st.isSymbolicLink() || fs.readFileSync(file, 'utf8') !== content) throw new Error(`private sandbox config file was changed: ${name}`);
    } catch (e) {
      if (e.code !== 'ENOENT') throw e;
      try { fs.writeFileSync(file, content, { flag: 'wx', mode: 0o600 }); }
      catch (writeError) {
        if (writeError.code !== 'EEXIST') throw writeError;
        const st = fs.lstatSync(file);
        if (!st.isFile() || st.isSymbolicLink() || fs.readFileSync(file, 'utf8') !== content) throw new Error(`private sandbox config file was changed: ${name}`);
      }
    }
  }
  return assertSessionPath(sessionRoot, dir, 'private sandbox system configuration');
}
function mapRuntimePath(hostPath, sessionRoot) {
  hostPath = path.resolve(hostPath);
  if (!inside(sessionRoot, hostPath)) throw new Error('sandbox command is outside the private session tree');
  const resolved = fs.realpathSync(hostPath);
  if (!inside(sessionRoot, resolved)) throw new Error('sandbox command resolves outside the private session tree');
  return `/opt/portable/${path.relative(sessionRoot, hostPath).split(path.sep).join('/')}`;
}
function addMount(args, flag, source, target) { args.push(flag, source, target); }
function socketPath(p) {
  try { const real = fs.realpathSync(p); return fs.statSync(real).isSocket() ? real : null; } catch { return null; }
}
function sandboxExecEnv(runtimeRoot, sandboxRoot) {
  const roots = [runtimeRoot, sandboxRoot].filter(Boolean).map(root => path.resolve(root));
  const loaderPaths = [];
  for (const root of roots) {
    for (const rel of ['lib/x86_64-linux-gnu', 'lib64']) {
      const candidate = path.join(root, 'sandbox', rel);
      if (fs.existsSync(candidate) && fs.lstatSync(candidate).isDirectory() && !fs.lstatSync(candidate).isSymbolicLink()) loaderPaths.push(candidate);
    }
  }
  return { PATH: '/usr/bin:/bin', LANG: process.env.LANG || 'C.UTF-8', ...(loaderPaths.length ? { LD_LIBRARY_PATH: [...new Set(loaderPaths)].join(':') } : {}) };
}
function prepareDisplay(sessionRoot, bargs, envArgs) {
  const tempRoot = assertSessionPath(sessionRoot, path.join(sessionRoot, 'tmp'), 'private display temporary directory');
  fs.mkdirSync(tempRoot, { recursive: true, mode: 0o700 });
  const displayRoot = fs.mkdtempSync(path.join(tempRoot, 'display-'));
  fs.chmodSync(displayRoot, 0o700);
  const targets = [];
  const waylandName = process.env.WAYLAND_DISPLAY ? path.basename(process.env.WAYLAND_DISPLAY) : '';
  const runtime = process.env.WSLG_RUNTIME_DIR || process.env.XDG_RUNTIME_DIR || '';
  const waylandHost = waylandName ? socketPath(path.isAbsolute(process.env.WAYLAND_DISPLAY)
    ? process.env.WAYLAND_DISPLAY : path.join(runtime, waylandName)) : null;
  if (waylandHost && /^[A-Za-z0-9_.-]+$/.test(waylandName)) targets.push({ name: waylandName, host: waylandHost });
  let xName = '';
  const xDisplay = process.env.DISPLAY || '';
  const xMatch = /^:(\d+)(?:\.\d+)?$|^(?:unix):([0-9]+)(?:\.\d+)?$|^(?:localhost|127\.0\.0\.1):(\d+)(?:\.\d+)?$/.exec(xDisplay);
  if (xMatch) {
    const number = xMatch[1] || xMatch[2] || xMatch[3]; xName = `X${number}`;
    let xHost = null;
    if (xMatch[3]) targets.push({ name: xName, tcpHost: '127.0.0.1', tcpPort: 6000 + Number(number) });
    else {
      const candidates = ['/tmp/.X11-unix', '/mnt/wslg/.X11-unix'];
      for (const dir of candidates) { xHost = socketPath(path.join(dir, xName)); if (xHost) break; }
      if (xHost) targets.push({ name: xName, host: xHost });
    }
  }
  if (targets.length) {
    let xAuth = '';
    if (process.env.XAUTHORITY && fs.existsSync(process.env.XAUTHORITY) && xName) {
      const st = fs.lstatSync(process.env.XAUTHORITY);
      if (st.isFile() && !st.isSymbolicLink() && st.size <= 65536) {
        fs.copyFileSync(process.env.XAUTHORITY, path.join(displayRoot, '.Xauthority'), fs.constants.COPYFILE_EXCL);
        fs.chmodSync(path.join(displayRoot, '.Xauthority'), 0o600); xAuth = '/tmp/.X11-unix/.Xauthority';
      }
    }
    // This is a private session directory, not the host's XDG runtime dir.
    // Tauri/GTK create transient tray resources here alongside the proxied
    // display sockets, so keep it writable only inside this sandbox.
    bargs.push('--dir', '/run/user', '--dir', '/run/user/0', '--bind', displayRoot, '/run/user/0');
    bargs.push('--dir', '/tmp/.X11-unix', '--ro-bind', displayRoot, '/tmp/.X11-unix');
    if (waylandHost) envArgs.push('--setenv', 'XDG_RUNTIME_DIR', '/run/user/0', '--setenv', 'WAYLAND_DISPLAY', waylandName);
    else if (runtime) envArgs.push('--setenv', 'XDG_RUNTIME_DIR', '/run/user/0');
    if (xName) {
      const xDisplay = xMatch?.[3] ? `:${xMatch[3]}` : process.env.DISPLAY;
      envArgs.push('--setenv', 'DISPLAY', xDisplay);
    }
    if (xAuth) envArgs.push('--setenv', 'XAUTHORITY', xAuth);
  }
  return { displayRoot, targets };
}
function buildSandbox({ sessionRoot, runtime, mode, command, args = [], workDir, network = true, extraEnv = {} }) {
  if (!['cc-switch', 'claude'].includes(mode)) throw new Error('sandbox mode must be cc-switch or claude');
  sessionRoot = assertPlainPath(path.resolve(sessionRoot), 'sessionRoot');
  if (!runtime || path.resolve(runtime.sessionRoot) !== sessionRoot) throw new Error('runtime does not belong to this private session');
  if (!Array.isArray(args) || args.some(a => typeof a !== 'string' || a.includes('\0'))) throw new Error('sandbox arguments must be strings without NUL bytes');
  if (typeof network !== 'boolean') throw new Error('network must be a boolean');
  if (typeof command !== 'string' || command.includes('\0')) throw new Error('sandbox command is invalid');
  const bwrap = assertSessionPath(sessionRoot, runtime.bwrap, 'bubblewrap executable');
  const runtimeRoot = assertSessionPath(sessionRoot, runtime.runtimeRoot, 'runtime directory');
  const pythonRoot = assertSessionPath(sessionRoot, path.join(sessionRoot, 'python'), 'managed Python runtime');
  const home = assertSessionPath(sessionRoot, mode === 'cc-switch' ? runtime.home : runtime.claudeHome, 'private HOME');
  const ccConfig = assertSessionPath(sessionRoot, runtime.ccConfig, 'portable CC Switch configuration');
  const claudeConfig = assertSessionPath(sessionRoot, runtime.claudeConfig, 'portable Claude configuration');
  const temp = assertSessionPath(sessionRoot, path.join(sessionRoot, 'tmp'), 'private temp directory');
  const npmPrefix = assertSessionPath(sessionRoot, runtime.npmPrefix, 'managed npm prefix');
  const npmCache = assertSessionPath(sessionRoot, runtime.npmCache, 'managed npm cache');
  const minimalEtc = prepareMinimalEtc(sessionRoot);
  const git = assertSessionPath(sessionRoot, runtime.git, 'managed Git executable');
  workDir = mode === 'claude' ? assertWorkDirectory(workDir || runtime.workDir) : assertSessionPath(sessionRoot, path.resolve(workDir || runtime.workDir), 'working directory');
  for (const d of [home, ccConfig, claudeConfig, temp, npmPrefix, npmCache, workDir]) fs.mkdirSync(d, { recursive: true, mode: 0o700 });
  const guestCmd = mapRuntimePath(command, sessionRoot);
  // The CC Switch harness has no project worktree: keep its cwd inside its
  // private HOME. Only Claude receives the explicitly selected /workspace.
  const guestCwd = mode === 'claude' ? '/workspace' : '/home/portable';
  const bargs = [
    '--clearenv', '--die-with-parent', '--new-session', '--unshare-user', '--unshare-pid', '--unshare-ipc', '--unshare-uts',
    '--uid', '0', '--gid', '0',
    '--ro-bind', '/usr', '/usr', '--ro-bind', '/bin', '/bin', '--ro-bind', '/sbin', '/sbin',
    '--ro-bind', '/lib', '/lib', '--ro-bind', '/lib64', '/lib64', '--tmpfs', '/etc',
    '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/run', '--tmpfs', '/tmp',
    '--dir', '/home', '--dir', '/home/portable', '--dir', '/harness', '--dir', '/config', '--dir', '/workspace', '--dir', '/opt', '--dir', '/opt/portable', '--dir', '/opt/portable/cache', '--dir', '/mnt',
    '--ro-bind', runtimeRoot, '/opt/portable/runtime', '--ro-bind', pythonRoot, '/opt/portable/python',
  ];
  if (!network) bargs.push('--unshare-net');
  bargs.push('--dir', '/etc/ssl');
  if (fs.existsSync('/etc/ssl/certs') && fs.lstatSync('/etc/ssl/certs').isDirectory()) bargs.push('--dir', '/etc/ssl/certs', '--ro-bind', '/etc/ssl/certs', '/etc/ssl/certs');
  if (fs.existsSync('/etc/fonts') && fs.lstatSync('/etc/fonts').isDirectory()) bargs.push('--dir', '/etc/fonts', '--ro-bind', '/etc/fonts', '/etc/fonts');
  // The app bundles GLib/GIO. Hide host GIO plugins at the system lookup path
  // to avoid loading ABI-incompatible host modules into the bundled GTK.
  const bundledGio = path.join(runtime.appDir, 'usr', 'lib', 'x86_64-linux-gnu', 'gio', 'modules');
  if (mode === 'cc-switch' && fs.existsSync(bundledGio) && fs.lstatSync(bundledGio).isDirectory()) {
    bargs.push('--ro-bind', bundledGio, '/usr/lib/x86_64-linux-gnu/gio/modules');
  }
  for (const name of ['passwd', 'group', 'nsswitch.conf', 'hosts', 'resolv.conf', 'os-release', 'npm-user.npmrc', 'npm-global.npmrc']) {
    const dest = name.startsWith('npm-') ? `/etc/${name}` : `/etc/${name}`;
    addMount(bargs, '--ro-bind', path.join(minimalEtc, name), dest);
  }
  // The minimal directory starts as a tmpfs so its individual public files
  // can be assembled without exposing host /etc; lock the completed tree.
  bargs.push('--remount-ro', '/etc');
  if (mode === 'cc-switch') {
    addMount(bargs, '--bind', home, '/home/portable');
    // The bundled WebKit helper resolves WebKitNetworkProcess relative to cwd
    // as ./lib/.... Keep that private-home lookup read-only and point it at the
    // staged AppImage's verified library tree.
    const appLib = path.join(runtime.appDir, 'usr', 'lib');
    if (fs.existsSync(appLib) && fs.lstatSync(appLib).isDirectory()) {
      bargs.push('--dir', '/home/portable/lib', '--ro-bind', appLib, '/home/portable/lib');
    }
    addMount(bargs, '--bind', ccConfig, '/harness/cc-switch');
    addMount(bargs, '--bind', claudeConfig, '/config/claude');
    addMount(bargs, '--bind', npmPrefix, '/opt/portable/npm');
    addMount(bargs, '--bind', npmCache, '/opt/portable/cache/npm');
  } else {
    addMount(bargs, '--bind', home, '/home/portable');
    addMount(bargs, '--bind', claudeConfig, '/config/claude');
    addMount(bargs, '--bind', workDir, '/workspace');
    addMount(bargs, '--bind', npmPrefix, '/opt/portable/npm');
    addMount(bargs, '--bind', npmCache, '/opt/portable/cache/npm');
  }
  // WSLg's display sockets are the only host runtime sockets exposed. No host
  // home, removable mounts, DBus, agent sockets, credential stores or /run.
  const envArgs = [];
  const display = mode === 'cc-switch' ? prepareDisplay(sessionRoot, bargs, envArgs) : { displayRoot: null, targets: [] };
  if (mode === 'cc-switch' && command === runtime.ccSwitch) {
    try {
      const dbusStat = fs.statSync('/usr/bin/dbus-run-session');
      if (!dbusStat.isFile() || !(dbusStat.mode & 0o111)) throw new Error();
    } catch { throw new Error('CC Switch GUI needs /usr/bin/dbus-run-session; no host package was installed.'); }
    if (display.targets.length === 0) throw new Error('CC Switch GUI needs an active X11 or Wayland display socket.');
  }
  // bubblewrap may re-exec itself after entering namespaces. Keep its private
  // libraries reachable at the same absolute path during that re-exec; this
  // exposes only the already read-only staged runtime tree.
  const runtimeParts = runtimeRoot.split(path.sep).filter(Boolean);
  let runtimeTarget = '';
  for (const part of runtimeParts) {
    runtimeTarget += `/${part}`;
    if (runtimeTarget !== '/tmp' && runtimeTarget !== '/home' && runtimeTarget !== '/mnt' && runtimeTarget !== '/opt' && runtimeTarget !== '/run') bargs.push('--dir', runtimeTarget);
  }
  addMount(bargs, '--ro-bind', runtimeRoot, runtimeRoot);
  const guestPythonBin = mapRuntimePath(path.dirname(runtime.python), sessionRoot);
  const guestUvBin = mapRuntimePath(path.dirname(runtime.uv), sessionRoot);
  const guestPython = mapRuntimePath(runtime.python, sessionRoot);
  bargs.push('--chdir', guestCwd, '--setenv', 'HOME', '/home/portable', '--setenv', 'XDG_CONFIG_HOME', '/home/portable/.config',
    '--setenv', 'XDG_DATA_HOME', '/home/portable/.local/share',
    '--setenv', 'XDG_CACHE_HOME', '/home/portable/.cache',
    '--setenv', 'TMPDIR', '/tmp', '--setenv', 'PATH', `/opt/portable/npm/bin:${guestPythonBin}:${guestUvBin}:/opt/portable/${path.relative(sessionRoot, path.dirname(runtime.node)).split(path.sep).join('/')}:/opt/portable/${path.relative(sessionRoot, path.dirname(git)).split(path.sep).join('/')}:/usr/local/bin:/usr/bin:/bin`,
    '--setenv', 'npm_config_prefix', '/opt/portable/npm', '--setenv', 'npm_config_cache', '/opt/portable/cache/npm',
    '--setenv', 'npm_config_userconfig', '/etc/npm-user.npmrc', '--setenv', 'npm_config_globalconfig', '/etc/npm-global.npmrc',
    '--setenv', 'npm_config_registry', 'https://registry.npmjs.org/', '--setenv', 'TZ', 'UTC',
    '--setenv', 'UV_PYTHON_INSTALL_DIR', '/opt/portable/python', '--setenv', 'UV_PYTHON_DOWNLOADS', 'never',
    '--setenv', 'UV_NO_CONFIG', '1', '--setenv', 'UV_CACHE_DIR', '/home/portable/.cache/uv',
    '--setenv', 'UV_PROJECT_ENVIRONMENT', '/home/portable/.venv', '--setenv', 'UV_PYTHON', guestPython,
    '--setenv', 'UV_PYTHON_PREFERENCE', 'only-managed', '--setenv', 'UV_LINK_MODE', 'copy',
    '--setenv', 'CLAUDE_CONFIG_DIR', '/config/claude',
    '--setenv', 'GIT_EXEC_PATH', '/opt/portable/runtime/git/usr/lib/git-core', '--setenv', 'GIT_CONFIG_NOSYSTEM', '1');
  for (const k of ['LANG', 'LC_ALL', 'TERM']) {
    if (process.env[k]) bargs.push('--setenv', k, process.env[k]);
  }
  // Secret provider values are never included in argv: bwrap reads the
  // NUL-delimited tail from an anonymous pipe (FD 3).
  const env = sandboxExecEnv(runtimeRoot, runtime.sandboxRoot);
  if (!extraEnv || typeof extraEnv !== 'object' || Array.isArray(extraEnv) || ![Object.prototype, null].includes(Object.getPrototypeOf(extraEnv))) throw new Error('provider environment must be a plain object');
  const secretEnvArgs = [];
  for (const [key, value] of Object.entries(extraEnv || {})) {
    if (!ENV_ALLOWLIST.has(key) || typeof value !== 'string' || value.length > 8192 || /[\0\n]/.test(value)) throw new Error(`unsupported provider environment entry: ${key}`);
    if (key === 'ANTHROPIC_BASE_URL') {
      let parsed; try { parsed = new URL(value); } catch { throw new Error('ANTHROPIC_BASE_URL must be a valid HTTP(S) URL'); }
      if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error('ANTHROPIC_BASE_URL must not contain credentials and must use HTTP(S)');
    }
    secretEnvArgs.push('--setenv', key, value);
  }
  bargs.push(...envArgs);
  if (mode === 'claude') bargs.push('--setenv', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', '1');
  if (secretEnvArgs.length) bargs.push('--args', '3');
  bargs.push('--');
  // CC Switch expects a desktop session bus. Give it an isolated private
  // session bus owned by this process tree; never inherit or mount the host
  // DBus socket/address.
  let commandOffset;
  if (mode === 'cc-switch') {
    bargs.push('/usr/bin/dbus-run-session', '--');
    if (command === runtime.ccSwitch) {
      // AppImage-bundled GLib must be used by the GUI and its WebKit children,
      // while dbus-run-session itself must use the host's matching system GLib.
      // Put the bundle loader paths on the application command only.
      commandOffset = bargs.length;
      bargs.push('/usr/bin/env',
        'LD_LIBRARY_PATH=/opt/portable/runtime/cc-switch/squashfs-root/usr/lib:/opt/portable/runtime/cc-switch/squashfs-root/usr/lib/x86_64-linux-gnu',
        'APPIMAGE=/opt/portable/runtime/cc-switch.AppImage',
        'APPDIR=/opt/portable/runtime/cc-switch/squashfs-root', guestCmd, ...args);
    } else { commandOffset = bargs.length; bargs.push(guestCmd, ...args); }
  } else { commandOffset = bargs.length; bargs.push(guestCmd, ...args); }
  return { executable: bwrap, args: bargs, env, command: guestCmd, workDir: guestCwd, mode, network: !!network, display,
    commandOffset, secretArgs: secretEnvArgs.length ? Buffer.from(`${secretEnvArgs.join('\0')}\0`) : null };
}
function launchSandbox(config, options = {}) {
  const spec = config.executable && Array.isArray(config.args) ? { ...config, args: [...config.args] } : buildSandbox(config);
  const trackSetup = options.trackSetup === true;
  if (trackSetup) {
    if (!Number.isInteger(spec.commandOffset) || spec.commandOffset < 0 || spec.commandOffset >= spec.args.length) throw new Error('sandbox readiness tracking needs a generated command offset');
    const command = spec.args.slice(spec.commandOffset);
    if (!command.length) throw new Error('sandbox guest command is missing');
    spec.args.splice(spec.commandOffset, command.length, '/bin/sh', '-c', 'printf "READY\\n" >&4; exec 4>&-; exec "$@"', 'portable-sandbox-ready', ...command);
  }
  const proxies = [];
  for (const target of spec.display?.targets || []) {
    const local = path.join(spec.display.displayRoot, target.name);
    const server = net.createServer(client => {
      const upstream = target.host ? net.createConnection(target.host) : net.createConnection(target.tcpPort, target.tcpHost);
      client.pipe(upstream); upstream.pipe(client);
      client.on('error', () => upstream.destroy()); upstream.on('error', () => client.destroy());
    });
    server.on('error', error => { spec.displayError = error; });
    server.listen(local);
    proxies.push(server);
  }
  let stdio = options.stdio || 'inherit';
  if (spec.secretArgs || trackSetup) {
    if (Array.isArray(stdio)) {
      stdio = [...stdio];
      while (stdio.length < 3) stdio.push('inherit');
      if (spec.secretArgs) stdio[3] = 'pipe';
      if (trackSetup) stdio[4] = 'pipe';
    } else {
      const inherited = stdio;
      stdio = [inherited, inherited, inherited, spec.secretArgs ? 'pipe' : 'ignore', trackSetup ? 'pipe' : 'ignore'];
    }
  }
  const child = spawn(spec.executable, spec.args, { cwd: path.dirname(spec.executable), env: spec.env, stdio, detached: true });
  if (spec.secretArgs) {
    const bytes = spec.secretArgs; spec.secretArgs = null;
    const pipe = child.stdio?.[3];
    if (pipe) {
      pipe.once('error', () => bytes.fill(0));
      pipe.end(bytes, () => bytes.fill(0));
    } else bytes.fill(0);
  }
  if (trackSetup) {
    let readyResolve; let readyReject; let settled = false; let buffered = '';
    const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
    // The caller may only care about child exit. Mark the rejection observed
    // immediately while leaving the original promise available to await.
    ready.catch(() => {});
    const fd = child.stdio?.[4];
    const timer = setTimeout(() => finish(new Error('sandbox namespace setup readiness timed out')), options.readyTimeout || 20000);
    timer.unref?.();
    const finish = error => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (error) readyReject(error); else readyResolve();
    };
    if (!fd) finish(new Error('sandbox readiness pipe was not created'));
    else {
      fd.setEncoding('utf8');
      fd.on('data', chunk => {
        buffered += chunk;
        if (buffered.length > 128) return finish(new Error('sandbox readiness marker exceeded its limit'));
        const at = buffered.indexOf('READY\n');
        if (at !== -1) {
          if (at !== 0) return finish(new Error('unexpected data on sandbox readiness pipe'));
          finish();
        }
      });
      fd.once('error', error => finish(error));
      fd.once('end', () => { if (!settled) finish(new Error('sandbox exited before namespace setup completed')); });
    }
    child.once('exit', (code, signal) => { if (!settled) finish(new Error(`sandbox exited before namespace setup completed (${code ?? signal})`)); });
    child.once('error', error => { if (!settled) finish(error); });
    child.sandboxReady = ready;
  }
  child.displayProxies = proxies;
  const closeProxies = () => {
    for (const server of proxies) server.close();
    for (const target of spec.display?.targets || []) {
      const p = path.join(spec.display.displayRoot, target.name);
      try { if (fs.lstatSync(p).isSocket()) fs.unlinkSync(p); } catch {}
    }
  };
  child.once('exit', closeProxies);
  child.once('error', closeProxies);
  return child;
}

module.exports = { buildSandbox, launchSandbox, sandboxExecEnv };
