'use strict';

// Linux side of the USB portable runtime. Executables remain in archives on
// the removable volume (which may be FAT32/noexec); each session gets a private
// executable copy on the host's Linux filesystem.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ASSET_DIRS = ['runtime/linux-x64', 'tools/linux-x64', 'npm-global/linux-x64'];
const HASH_PATHS = [
  'runtime/linux-x64/node-runtime.tar.xz', 'runtime/linux-x64/uv-runtime.tar.gz',
  'runtime/linux-x64/bwrap-runtime.tar.gz', 'runtime/linux-x64/cc-switch.AppImage',
  'tools/linux-x64/python312-runtime.tar.gz', 'tools/linux-x64/python312-manifest.json',
  'tools/linux-x64/git-runtime.tar.gz',
];
const EXPECTED_VERSIONS = { node: '22.23.3', uv: '0.8.22', ccSwitch: '3.20.4' };
const EXPECTED_CC_SHA256 = 'c8d66d8193fd00fd12239bd06a8c50f517badbf50d9020a4662e95e907b318ef';

function within(root, p) {
  const rel = path.relative(root, p);
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) throw new Error('path escaped its managed root');
  return p;
}
function inside(root, p) {
  try { within(root, p); return true; } catch { return false; }
}
function regular(p) { try { return fs.lstatSync(p).isFile(); } catch { return false; } }
function rejectSymlinkPath(p, allowMissingLeaf = false) {
  const full = path.resolve(p); const components = [];
  let cursor = full;
  while (true) {
    components.push(cursor);
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  for (const item of components.reverse()) {
    try { const st = fs.lstatSync(item); if (st.isSymbolicLink()) throw new Error(`path crosses symbolic link: ${item}`); }
    catch (e) { if (e.code === 'ENOENT' && allowMissingLeaf && item === full) continue; throw e; }
  }
  return full;
}
function digest(p) {
  const crypto = require('node:crypto');
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}
function status(root, options = {}) {
  root = rejectSymlinkPath(root);
  if (process.platform !== 'linux') throw new Error('Linux runtime requested on a non-Linux host');
  if (process.arch !== 'x64') throw new Error(`Linux runtime is x64 only; current Node architecture is ${process.arch}`);
  if (options.arch && options.arch !== 'x64' && options.arch !== 'x86_64') throw new Error('Only Linux x86_64 is currently supported');
  const paths = Object.fromEntries(ASSET_DIRS.map(d => [d, within(root, path.join(root, d))]));
  const missing = [];
  for (const name of HASH_PATHS) {
    const candidate = path.join(root, name);
    try { rejectSymlinkPath(candidate); } catch { missing.push(`plain path ${name}`); }
    if (!regular(candidate)) missing.push(name);
  }
  const manifestPath = path.join(paths['runtime/linux-x64'], 'manifest.json');
  try { rejectSymlinkPath(manifestPath); } catch { missing.push('plain manifest.json path'); }
  let manifest = null;
  if (regular(manifestPath)) {
    try { manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); } catch { missing.push('valid manifest.json'); }
  } else missing.push('manifest.json');
  let claude = null;
  try { claude = resolveClaudeBundle(root); } catch (e) { missing.push(`Claude Code runtime bundle (${e.message})`); }
  let integrity = true;
  if (!manifest || manifest.platform !== 'linux' || manifest.arch !== 'x64') { integrity = false; missing.push('Linux x64 manifest schema'); }
  if (manifest?.versions?.node !== EXPECTED_VERSIONS.node || manifest?.versions?.uv !== EXPECTED_VERSIONS.uv || manifest?.versions?.ccSwitch !== EXPECTED_VERSIONS.ccSwitch) { integrity = false; missing.push('pinned runtime versions'); }
  const hashes = manifest?.sha256;
  if (!hashes || typeof hashes !== 'object' || Array.isArray(hashes)) { integrity = false; missing.push('complete hash inventory'); }
  else {
    const keys = Object.keys(hashes).sort();
    const expectedKeys = [...HASH_PATHS].sort();
    if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) { integrity = false; missing.push('exact canonical hash inventory'); }
    for (const name of expectedKeys) {
      const expected = hashes[name];
      if (typeof expected !== 'string' || !/^[0-9a-f]{64}$/.test(expected) || !regular(path.join(root, name)) || digest(path.join(root, name)) !== expected) {
        integrity = false; missing.push(`verified ${name}`);
      }
    }
    if (hashes['runtime/linux-x64/cc-switch.AppImage'] !== EXPECTED_CC_SHA256) {
      integrity = false; missing.push('official CC Switch v3.20.4 AppImage digest');
    }
  }
  const glibc = process.report?.getReport?.().header?.glibcVersionRuntime || null;
  const glibcVersion = glibc?.match(/^(\d+)\.(\d+)$/);
  const glibcSupported = !!glibcVersion && (Number(glibcVersion[1]) > 2 || (Number(glibcVersion[1]) === 2 && Number(glibcVersion[2]) >= 38));
  if (!glibcSupported) missing.push('glibc >= 2.38 (Ubuntu 24.04 / Debian 13 class or newer)');
  const tarReady = regular('/usr/bin/tar');
  if (!tarReady) missing.push('system archive tool /usr/bin/tar');
  const ready = missing.length === 0 && integrity && glibcSupported && tarReady;
  return { root, platform: 'linux', arch: 'x64', ready, missing: [...new Set(missing)], versions: { ...(manifest?.versions || {}), claude: claude?.manifest.version || null }, assets: paths, integrity, host: { glibc, minimumGlibc: '2.38' } };
}
function prepareRuntime(root, options = {}) { return status(root, options); }
function run(exe, args, env) {
  const r = spawnSync(exe, args, { env, encoding: 'utf8', timeout: 120000 });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`${path.basename(exe)} failed (${r.status}): ${(r.stderr || '').slice(0, 1200)}`);
  return (r.stdout || '').trim();
}
function extract(archive, dest, format) {
  const tar = '/usr/bin/tar';
  if (!regular(tar)) throw new Error('portable staging requires the standard system archive utility /usr/bin/tar (no packages are installed)');
  ensureSafeDir(dest);
  if (fs.readdirSync(dest).length !== 0) throw new Error('runtime extraction target is not empty');
  const listing = spawnSync(tar, [format === 'xz' ? '-tJf' : '-tzf', archive], { encoding: 'utf8', timeout: 120000, env: { PATH: '/usr/bin:/bin' }, maxBuffer: 16 * 1024 * 1024 });
  if (listing.status !== 0) throw new Error(`runtime archive listing failed: ${listing.stderr}`);
  const names = listing.stdout.split('\n').filter(Boolean);
  if (names.length > 300000) throw new Error('runtime archive entry limit exceeded');
  for (const name of names) {
    const normalized = path.posix.normalize(name.replace(/^\.\//, ''));
    if (name.startsWith('/') || normalized === '..' || normalized.startsWith('../') || name.includes('\\')) throw new Error('runtime archive contains an unsafe path');
  }
  const detailed = spawnSync(tar, [format === 'xz' ? '-tvJf' : '-tvzf', archive], { encoding: 'utf8', timeout: 120000, env: { PATH: '/usr/bin:/bin' }, maxBuffer: 32 * 1024 * 1024 });
  if (detailed.status !== 0) throw new Error(`runtime archive detail listing failed: ${detailed.stderr}`);
  let expanded = 0;
  for (const line of detailed.stdout.split('\n')) {
    if (!line) continue;
    const kind = line[0];
    if (!'-dlh'.includes(kind)) throw new Error('runtime archive contains a special filesystem entry');
    const fileMatch = line.match(/^\S+\s+\S+\s+(\d+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+/);
    if (fileMatch && kind === '-') { expanded += Number(fileMatch[1]); if (expanded > 15 * 1024 * 1024 * 1024) throw new Error('runtime archive unpacked size limit exceeded'); }
    const marker = kind === 'l' ? ' -> ' : kind === 'h' ? ' link to ' : '';
    if (marker) {
      const at = line.indexOf(marker);
      if (at < 0) throw new Error('runtime archive link metadata is invalid');
      const meta = line.slice(0, at);
      const pathStart = meta.search(/(?:\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+)/);
      if (pathStart < 0) throw new Error('runtime archive link path metadata is invalid');
      const source = meta.slice(pathStart).replace(/^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+/, '');
      const target = line.slice(at + marker.length);
      if (target.startsWith('/')) throw new Error('runtime archive contains an absolute link');
      const basedir = kind === 'l' ? path.posix.dirname(source) : '';
      const resolved = path.posix.normalize(path.posix.join(basedir, target));
      if (resolved === '..' || resolved.startsWith('../')) throw new Error('runtime archive link escapes its root');
    }
  }
  const args = format === 'xz'
    ? ['-xJf', archive, '-C', dest, '--strip-components=1']
    : ['-xzf', archive, '-C', dest, '--strip-components=1'];
  args.push('--no-same-owner', '--no-same-permissions');
  const r = spawnSync(tar, args, { encoding: 'utf8', env: { PATH: '/usr/bin:/bin' }, timeout: 300000 });
  if (r.status !== 0) throw new Error(`runtime extraction failed: ${r.stderr}`);
}

function resolveClaudeBundle(root) {
  const activePath = path.join(root, 'npm-global/linux-x64/active.json');
  rejectSymlinkPath(activePath);
  const active = JSON.parse(fs.readFileSync(activePath, 'utf8'));
  if (typeof active.slot !== 'string' || !/^slots\/\d+\.\d+\.\d+-[0-9a-f]{12}$/.test(active.slot) || !/^\d+\.\d+\.\d+$/.test(active.version) || !/^[0-9a-f]{64}$/.test(active.archiveSha256)) throw new Error('active package pointer is invalid');
  const slot = path.join(root, 'npm-global/linux-x64', active.slot);
  const archive = path.join(slot, 'claude-package.tar.gz');
  const manifestPath = path.join(slot, 'manifest.json');
  for (const p of [slot, archive, manifestPath]) rejectSymlinkPath(p);
  if (!regular(archive) || !regular(manifestPath)) throw new Error('active package slot is incomplete');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (manifest.name !== '@anthropic-ai/claude-code' || manifest.version !== active.version || manifest.archiveSha256 !== active.archiveSha256 || digest(archive) !== active.archiveSha256 || !/^[0-9a-f]{64}$/.test(manifest.archiveSha256)) throw new Error('active package archive or metadata hash does not match');
  if (manifest.registryIntegrity !== null && !/^sha512-[A-Za-z0-9+/]+=*$/.test(manifest.registryIntegrity)) throw new Error('active package registry integrity metadata is invalid');
  return { active, slot, archive, manifest };
}
function ensureDir(p) { fs.mkdirSync(p, { recursive: true, mode: 0o700 }); }
function ensureSafeDir(p) {
  p = path.resolve(p);
  let cursor = p; const absent = [];
  while (!fs.existsSync(cursor)) {
    absent.push(cursor);
    const parent = path.dirname(cursor);
    if (parent === cursor) throw new Error('invalid staging directory ancestry');
    cursor = parent;
  }
  while (true) {
    const st = fs.lstatSync(cursor);
    if (st.isSymbolicLink() || !st.isDirectory()) throw new Error(`staging path crosses a non-directory or symbolic link: ${cursor}`);
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  ensureDir(p);
  return rejectSymlinkPath(p);
}
function createFreshDir(p) {
  p = path.resolve(p);
  ensureSafeDir(path.dirname(p));
  if (fs.existsSync(p)) throw new Error(`refusing to replace existing session runtime path: ${p}`);
  fs.mkdirSync(p, { mode: 0o700 });
  return rejectSymlinkPath(p);
}
function stageRuntime(root, sessionRoot) {
  root = rejectSymlinkPath(root); sessionRoot = path.resolve(sessionRoot);
  const s = status(root);
  if (!s.ready) throw new Error(`portable Linux runtime is incomplete: ${s.missing.join(', ')}`);
  ensureSafeDir(sessionRoot);
  const runtimeRoot = path.join(sessionRoot, 'runtime');
  createFreshDir(runtimeRoot);
  const nodeDir = path.join(runtimeRoot, 'node');
  const uvDir = path.join(runtimeRoot, 'uv');
  const bwDir = path.join(runtimeRoot, 'sandbox');
  const ccDir = path.join(runtimeRoot, 'cc-switch');
  // Always populate fresh private session paths; never execute from the USB.
  for (const d of [nodeDir, uvDir, bwDir, ccDir]) createFreshDir(d);
  const rt = s.assets['runtime/linux-x64'];
  extract(path.join(rt, 'node-runtime.tar.xz'), nodeDir, 'xz');
  extract(path.join(rt, 'uv-runtime.tar.gz'), uvDir, 'gz');
  extract(path.join(rt, 'bwrap-runtime.tar.gz'), bwDir, 'gz');
  const gitDir = path.join(runtimeRoot, 'git');
  createFreshDir(gitDir);
  extract(path.join(root, 'tools/linux-x64/git-runtime.tar.gz'), gitDir, 'gz');
  const pythonDir = path.join(sessionRoot, 'python');
  createFreshDir(pythonDir);
  extract(path.join(root, 'tools/linux-x64/python312-runtime.tar.gz'), pythonDir, 'gz');
  const npmPrefix = path.join(sessionRoot, 'npm');
  const claudeBundle = resolveClaudeBundle(root);
  createFreshDir(npmPrefix);
  extract(claudeBundle.archive, npmPrefix, 'gz');
  // AppImage is a read-only executable payload. Extract AppDir to the session;
  // do not depend on FUSE or execute the image from the removable volume.
  const appImage = path.join(rt, 'cc-switch.AppImage');
  const localImage = path.join(runtimeRoot, 'cc-switch.AppImage');
  rejectSymlinkPath(localImage, true);
  fs.copyFileSync(appImage, localImage, fs.constants.COPYFILE_EXCL);
  fs.chmodSync(localImage, 0o700);
  const extractResult = spawnSync(localImage, ['--appimage-extract'], {
    cwd: ccDir, encoding: 'utf8', timeout: 120000,
    env: { PATH: '/usr/bin:/bin', HOME: path.join(sessionRoot, 'tmp'), LANG: 'C.UTF-8' },
  });
  if (extractResult.status !== 0) throw new Error(`CC Switch AppImage extraction failed: ${extractResult.stderr || extractResult.error}`);
  const appDir = path.join(ccDir, 'squashfs-root');
  const find = (base, predicate) => {
    const todo = [base];
    while (todo.length) {
      const dir = todo.pop();
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, ent.name);
        if (ent.isDirectory()) todo.push(p); else if (predicate(p, ent.name)) return p;
      }
    }
  };
  // Use the official AppRun wrapper so AppImage GTK/GIO/WebKit environment
  // hooks execute for the extracted AppDir (the raw Tauri binary skips them).
  const ccSwitch = path.join(appDir, 'AppRun');
  if (!regular(ccSwitch) || !(fs.statSync(ccSwitch).mode & 0o111)) throw new Error('official CC Switch AppRun wrapper is unavailable');
  const node = find(nodeDir, (p, name) => name === 'node' && fs.statSync(p).mode & 0o111);
  const uv = find(uvDir, (p, name) => name === 'uv' && fs.statSync(p).mode & 0o111);
  const bwrap = find(bwDir, (p, name) => name === 'bwrap' && fs.statSync(p).mode & 0o111);
  const python = find(pythonDir, (p, name) => /^python3\.12$/.test(name) && fs.statSync(p).mode & 0o111);
  const git = find(gitDir, (p, name) => name === 'git' && p.endsWith('/usr/bin/git') && fs.statSync(p).mode & 0o111);
  if (!node || !uv || !bwrap || !ccSwitch || !python || !git) throw new Error('staged runtime is missing node, uv, Python 3.12, Git, bwrap or CC Switch executable');
  const nodeBin = path.dirname(node);
  const npmCommand = path.join(nodeBin, 'npm');
  const npmResolved = fs.realpathSync(npmCommand);
  if (!inside(nodeDir, npmResolved)) throw new Error('bundled npm command resolves outside the verified Node runtime');
  const npmBin = path.join(npmPrefix, 'bin');
  ensureDir(npmBin);
  fs.symlinkSync(path.relative(npmBin, node), path.join(npmBin, 'node'));
  fs.symlinkSync(path.relative(npmBin, npmCommand), path.join(npmBin, 'npm'));
  const probeEnv = { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8' };
  const nodeVersion = run(node, ['--version'], probeEnv);
  const uvVersion = run(uv, ['--version'], probeEnv);
  const pythonVersion = run(python, ['--version'], probeEnv);
  const home = path.join(sessionRoot, 'config', 'cc-switch', 'home');
  const claudeHome = path.join(sessionRoot, 'config', 'claude', 'home');
  const ccConfig = path.join(sessionRoot, 'harness', 'cc-switch');
  const claudeConfig = path.join(ccConfig, 'claude');
  const workDir = path.join(sessionRoot, 'work');
  for (const d of [home, claudeHome, claudeConfig, workDir, path.join(home, '.config'), path.join(home, '.local', 'share'), path.join(home, '.cache'), path.join(claudeHome, '.config'), path.join(claudeHome, '.local', 'share'), path.join(claudeHome, '.cache'), path.join(sessionRoot, 'tmp'), path.join(sessionRoot, 'cache', 'npm')]) ensureSafeDir(d);
  return { sessionRoot, runtimeRoot, node, uv, python, git, uvVersion,
    ccSwitch, bwrap,
    appDir, home, claudeHome, ccConfig, claudeConfig, workDir, nodeVersion, pythonVersion,
    claude: path.join(npmPrefix, 'bin', 'claude'), npmPrefix, npmCache: path.join(sessionRoot, 'cache', 'npm') };
}
function stagePython(root, sessionRoot) {
  root = rejectSymlinkPath(root); sessionRoot = path.resolve(sessionRoot);
  const validation = status(root);
  if (!validation.ready) throw new Error(`portable Linux runtime is incomplete: ${validation.missing.join(', ')}`);
  const manifestPath = path.join(root, 'runtime/linux-x64/manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const pyArchive = path.join(root, 'tools/linux-x64/python312-runtime.tar.gz');
  const uvArchive = path.join(root, 'runtime/linux-x64/uv-runtime.tar.gz');
  for (const [p, rel] of [[pyArchive, 'tools/linux-x64/python312-runtime.tar.gz'], [uvArchive, 'runtime/linux-x64/uv-runtime.tar.gz']]) {
    const expected = manifest.sha256?.[rel];
    if (!regular(p) || !/^[0-9a-f]{64}$/.test(expected || '') || digest(p) !== expected) throw new Error(`verified Linux ${rel} archive is unavailable`);
  }
  ensureSafeDir(sessionRoot);
  const stageRoot = path.join(sessionRoot, 'python-stage');
  createFreshDir(stageRoot);
  const pythonRoot = path.join(stageRoot, 'python');
  const uvRoot = path.join(stageRoot, 'uv');
  createFreshDir(pythonRoot); createFreshDir(uvRoot);
  extract(pyArchive, pythonRoot, 'gz'); extract(uvArchive, uvRoot, 'gz');
  const find = (base, predicate) => {
    const todo = [base];
    while (todo.length) {
      const dir = todo.pop();
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, ent.name);
        if (ent.isDirectory()) todo.push(p); else if (predicate(p, ent.name)) return p;
      }
    }
  };
  const python = find(pythonRoot, (p,n) => n === 'python3.12' && fs.statSync(p).mode & 0o111);
  const uv = find(uvRoot, (p,n) => n === 'uv' && fs.statSync(p).mode & 0o111);
  if (!python || !uv) throw new Error('staged managed Python runtime is incomplete');
  return { sessionRoot, python, uv, pythonVersion: run(python, ['--version'], { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8' }) };
}

// Persist an upgraded Claude Code package as an immutable, hash-addressed USB
// slot. The caller must stop its CC Switch child before invoking this. Only
// the Claude package and its launcher are exported; Node/npm links, npm cache,
// HOME, settings and credentials are deliberately excluded.
function exportClaudeRuntime(root, sessionRoot) {
  root = ensureSafeDir(path.resolve(root)); sessionRoot = rejectSymlinkPath(path.resolve(sessionRoot));
  if (process.platform !== 'linux' || process.arch !== 'x64') throw new Error('Claude runtime export is Linux x64 only');
  const prefix = path.join(sessionRoot, 'npm');
  rejectSymlinkPath(prefix);
  const packageDir = path.join(prefix, 'lib/node_modules/@anthropic-ai/claude-code');
  const pkgPath = path.join(packageDir, 'package.json');
  rejectSymlinkPath(pkgPath);
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  if (pkg.name !== '@anthropic-ai/claude-code' || !/^\d+\.\d+\.\d+$/.test(pkg.version)) throw new Error('managed Claude package metadata is invalid');
  const binRel = typeof pkg.bin === 'string' ? pkg.bin : pkg.bin?.claude;
  if (typeof binRel !== 'string' || !binRel || path.posix.isAbsolute(binRel) || binRel.includes('\\') || path.posix.normalize(binRel).startsWith('../')) throw new Error('Claude package has no safe declared claude executable');
  const packageBin = path.resolve(packageDir, ...binRel.split('/'));
  if (!inside(packageDir, packageBin)) throw new Error('Claude executable escapes its package');
  rejectSymlinkPath(packageBin);
  if (!regular(packageBin) || !(fs.statSync(packageBin).mode & 0o111)) throw new Error('Claude package executable is missing or not executable');
  const cli = path.join(prefix, 'bin/claude');
  rejectSymlinkPath(path.dirname(cli));
  const cliStat = fs.lstatSync(cli);
  if (!cliStat.isSymbolicLink() || path.resolve(path.dirname(cli), fs.readlinkSync(cli)) !== packageBin) throw new Error('Claude launcher does not point to the package-declared executable');
  // Reject links in the package that could cause archive traversal or include
  // content outside the managed npm prefix.
  const scopeDir = path.dirname(packageDir);
  const todo = [scopeDir];
  while (todo.length) {
    const dir = todo.pop();
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name); const st = fs.lstatSync(p);
      if (st.isSymbolicLink()) {
        const target = path.resolve(path.dirname(p), fs.readlinkSync(p));
        if (!inside(scopeDir, target)) throw new Error('Claude package scope contains a link outside its export tree');
      } else if (st.isDirectory()) todo.push(p);
      else if (!st.isFile()) throw new Error('Claude package contains a special filesystem entry');
    }
  }
  const temp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'aistick-claude-export-'));
  try {
    const content = path.join(temp, 'package'); fs.mkdirSync(content, { mode: 0o700 });
    fs.mkdirSync(path.join(content, 'lib/node_modules'), { recursive: true, mode: 0o700 });
    // The optional platform-specific native package is installed beside the
    // main package in the same npm scope, so retain the whole scope.
    fs.cpSync(scopeDir, path.join(content, 'lib/node_modules/@anthropic-ai'), { recursive: true, dereference: false, preserveTimestamps: true });
    fs.mkdirSync(path.join(content, 'bin'), { mode: 0o700 });
    fs.symlinkSync(`../lib/node_modules/@anthropic-ai/claude-code/${binRel}`, path.join(content, 'bin/claude'));
    const archive = path.join(temp, 'claude-package.tar.gz');
    const created = spawnSync('/usr/bin/tar', ['-czf', archive, '-C', temp, 'package'], { encoding: 'utf8', timeout: 300000, env: { PATH: '/usr/bin:/bin' } });
    if (created.status !== 0) throw new Error(`Claude package archive failed: ${created.stderr}`);
    const archiveSha256 = digest(archive);
    const slot = `slots/${pkg.version}-${archiveSha256.slice(0, 12)}`;
    const npmRoot = path.join(root, 'npm-global/linux-x64'); ensureSafeDir(npmRoot);
    const slotsRoot = path.join(npmRoot, 'slots'); ensureSafeDir(slotsRoot);
    const slotTarget = path.join(npmRoot, slot);
    if (!fs.existsSync(slotTarget)) {
      const staging = path.join(slotsRoot, `.stage-${process.pid}-${require('node:crypto').randomBytes(8).toString('hex')}`);
      fs.mkdirSync(staging, { mode: 0o700 });
      try {
        fs.copyFileSync(archive, path.join(staging, 'claude-package.tar.gz'), fs.constants.COPYFILE_EXCL);
        let registryIntegrity = null;
        const lockPath = path.join(prefix, 'lib/node_modules/.package-lock.json');
        try {
          rejectSymlinkPath(lockPath);
          const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
          const record = lock.packages?.['node_modules/@anthropic-ai/claude-code'];
          if (typeof record?.integrity === 'string' && /^sha512-[A-Za-z0-9+/]+=*$/.test(record.integrity)) registryIntegrity = record.integrity;
        } catch {}
        const manifest = { name: pkg.name, version: pkg.version, registryIntegrity, archiveSha256,
          source: registryIntegrity ? 'npm-package-lock-integrity' : 'managed-cc-switch-upgrade', exportedAt: new Date().toISOString() };
        fs.writeFileSync(path.join(staging, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
        fs.renameSync(staging, slotTarget);
      } catch (error) { fs.rmSync(staging, { recursive: true, force: true }); throw error; }
    }
    // Verify the slot before switching the pointer; a failed export never
    // damages the last working runtime.
    const slotArchive = path.join(slotTarget, 'claude-package.tar.gz');
    const slotManifestPath = path.join(slotTarget, 'manifest.json');
    rejectSymlinkPath(slotArchive); rejectSymlinkPath(slotManifestPath);
    if (!regular(slotArchive) || digest(slotArchive) !== archiveSha256) throw new Error('exported Claude slot failed hash verification');
    const savedManifest = JSON.parse(fs.readFileSync(slotManifestPath, 'utf8'));
    if (savedManifest.name !== pkg.name || savedManifest.version !== pkg.version || savedManifest.archiveSha256 !== archiveSha256 ||
        (savedManifest.registryIntegrity !== null && !/^sha512-[A-Za-z0-9+/]+=*$/.test(savedManifest.registryIntegrity))) throw new Error('exported Claude slot metadata did not validate');
    const active = { slot, version: pkg.version, archiveSha256 };
    const activePath = path.join(npmRoot, 'active.json'); const nextPath = `${activePath}.next-${process.pid}`;
    fs.writeFileSync(nextPath, `${JSON.stringify(active, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(nextPath, activePath);
    return { ...active, path: slotTarget, sha256: archiveSha256 };
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}

if (require.main === module) {
  const [action, root, sessionRoot] = process.argv.slice(2);
  try {
    const result = action === 'stage' ? stageRuntime(root, sessionRoot) : prepareRuntime(root);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (e) { process.stderr.write(`${e.message}\n`); process.exitCode = 1; }
}
module.exports = { prepareRuntime, stageRuntime, stagePython, exportClaudeRuntime, status, HASH_PATHS };
