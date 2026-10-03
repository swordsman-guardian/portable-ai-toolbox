'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const net = require('node:net');
const https = require('node:https');
const readline = require('node:readline');
const { StringDecoder } = require('node:string_decoder');
const { spawn } = require('node:child_process');
const store = require('./linux-encrypted-store.cjs');
const runtimeApi = require('./linux-runtime.cjs');
const sandboxApi = require('./linux-sandbox.cjs');
let nativeProxyApi = null;
try { nativeProxyApi = require('./linux-native-proxy.cjs'); } catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e; }
let usernsApi = null;
try { usernsApi = require('./linux-userns.cjs'); } catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e; }

const sessions = new Map();
let exitHandlersInstalled = false;
let shutdownPromise = null;
const sessionBase = (root) => path.join(root, 'sessions', 'linux');
const privateBase = () => path.join(os.tmpdir(), `portable-ai-${process.getuid ? process.getuid() : 'user'}`);

function ensurePrivateDir(dir) {
  assertNoLinks(dir);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  assertNoLinks(dir);
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.isSymbolicLink() || (process.getuid && st.uid !== process.getuid()) || (process.platform === 'linux' && (st.mode & 0o077))) throw new Error('Private runtime directory is not a user-owned mode-700 directory.');
  return dir;
}
function volumeIdentity(identity) { return { dev: String(identity.dev), source: identity.mountSource || '' }; }
function assertNoLinks(p) {
  let cur = path.resolve(p); const todo = [];
  while (true) { todo.push(cur); const parent = path.dirname(cur); if (parent === cur) break; cur = parent; }
  for (const item of todo.reverse()) { try { if (fs.lstatSync(item).isSymbolicLink()) throw new Error(`Managed path contains a symbolic link: ${item}`); } catch (e) { if (e.code !== 'ENOENT') throw e; } }
}
function atomicWrite(file, bytes) {
  assertNoLinks(path.dirname(file)); fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); assertNoLinks(path.dirname(file));
  const tmp = `${file}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  const fd = fs.openSync(tmp, 'wx', 0o600); try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(tmp, file);
}
function readRegularFileBounded(file, maxBytes, label = 'file') {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > maxBytes) throw new Error(`${label} is not a regular file or exceeds its size limit.`);
    const chunks = []; let total = 0; const chunk = Buffer.allocUnsafe(Math.min(1024 * 1024, maxBytes + 1));
    while (true) {
      const n = fs.readSync(fd, chunk, 0, Math.min(chunk.length, maxBytes + 1 - total), null);
      if (!n) break;
      total += n; if (total > maxBytes) throw new Error(`${label} exceeds its size limit.`);
      chunks.push(Buffer.from(chunk.subarray(0, n)));
    }
    return Buffer.concat(chunks, total);
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}
function writePrivateOwner(record) {
  if (!record.opened?.keyringBytes) throw new Error('Encrypted session keyring is unavailable for crash recovery metadata.');
  const children = [...record.children].filter((child) => Number.isSafeInteger(child.pid)).map((child) => {
    try { child.__portableOwner ||= processIdentity(child.pid); return { ...child.__portableOwner }; } catch { return null; }
  }).filter(Boolean);
  const meta = { version: 1, id: record.id, kind: record.kind, root: record.root, volume: volumeIdentity(record.identity), owner: { pid: process.pid, bootId: bootId(), start: processStartTime(process.pid) }, children,
    revision: record.opened.revision || null, keyring: record.opened.keyringBytes.toString('base64'), workHash: record.workHash || null };
  atomicWrite(path.join(record.dir, '.portable-session.json'), Buffer.from(JSON.stringify(meta), 'utf8'));
}

function authorizationProfileLoaded(authorization) {
  const name = authorization?.profile?.name;
  if (typeof name !== 'string' || !/^[A-Za-z0-9_-]+$/.test(name)) return null;
  try {
    return fs.readFileSync('/sys/kernel/security/apparmor/profiles', 'utf8')
      .split('\n').some((line) => line.startsWith(`${name} (`));
  } catch { return null; }
}

function ask(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (answer) => { rl.close(); resolve(answer.trim()); });
  });
}

function askSecret(label) {
  return new Promise((resolve, reject) => {
    if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== 'function') { reject(new Error('安全密码输入需要 TTY；非交互模式不接受明文密码。')); return; }
    process.stdout.write(`${label}: `);
    let value = '', decoder = new StringDecoder('utf8'), finished = false;
    const finish = (error, result) => {
      if (finished) return; finished = true;
      process.stdin.removeListener('data', onData);
      try { process.stdin.setRawMode(false); } catch {}
      process.stdin.pause(); process.stdout.write('\n');
      if (error) reject(error); else resolve(result);
    };
    const onData = (buf) => {
      for (const ch of decoder.write(buf)) {
        if (ch === '\n' || ch === '\r') { finish(null, value); return; }
        if (ch === '\u0003') { process.exitCode = 130; finish(new Error('已取消密码输入。')); return; }
        if (ch === '\u007f' || ch === '\b') value = Array.from(value).slice(0, -1).join(''); else value += ch;
      }
    };
    process.stdin.setRawMode(true); process.stdin.resume(); process.stdin.on('data', onData);
  });
}

async function unlock(root, create = false) {
  const status = store.storeStatus(root);
  if (status.state === 'Absent' && !create) throw new Error('No encrypted CC Switch configuration exists on this USB. Open Settings to create it.');
  if (['Corrupt', 'RecoveryRequired'].includes(status.state)) throw new Error(`Encrypted store is ${status.state}; writes are disabled.`);
  if (status.state === 'Absent' && create) {
    for (let i = 0; i < 3; i++) {
      const password = await askSecret('设置主密码');
      const confirm = await askSecret('再次输入主密码');
      if (password !== confirm) { console.log(`两次密码不一致（${i + 1}/3）。`); continue; }
      if (password.length < 1 || password.length > 1024) { console.log('主密码长度必须为 1 到 1024 个字符。'); continue; }
      return store.openStore(root, password, { create: true });
    }
    throw new Error('创建主密码失败三次。');
  }
  for (let i = 0; i < 3; i++) {
    const password = await askSecret('主密码');
    try { return await store.openStore(root, password, { create }); }
    catch (e) { if (i === 2) throw new Error('Unlock failed three times.'); console.log(`密码不正确或存储不可用（${i + 1}/3）。`); }
  }
}

function usbIdentity(root) {
  const st = fs.statSync(root);
  const real = fs.realpathSync(root); let mountId = null, mountSource = null;
  try {
    const unescape = (s) => s.replace(/\\([0-7]{3})/g, (_, n) => String.fromCharCode(parseInt(n, 8)));
    const records = fs.readFileSync('/proc/self/mountinfo', 'utf8').trim().split('\n').map((line) => {
      const pair = line.split(' - '), left = pair[0].split(/\s+/), right = (pair[1] || '').split(/\s+/);
      return { id: left[0], mount: unescape(left[4] || ''), source: unescape(right[1] || '') };
    }).filter((r) => r.mount && (real === r.mount || real.startsWith(r.mount.endsWith('/') ? r.mount : r.mount + '/')))
      .sort((a, b) => b.mount.length - a.mount.length);
    if (records[0]) { mountId = records[0].id; mountSource = records[0].source; }
  } catch {}
  return { dev: st.dev, ino: st.ino, real, mountId, mountSource };
}
function stillMounted(root, identity) {
  try { const now = usbIdentity(root); return now.dev === identity.dev && now.ino === identity.ino && now.real === identity.real && now.mountId === identity.mountId && now.mountSource === identity.mountSource; }
  catch { return false; }
}
function isSameOrWithin(candidate, base) { return candidate === base || candidate.startsWith(base.endsWith(path.sep) ? base : base + path.sep); }
function pathsOverlap(a, b) { return isSameOrWithin(a, b) || isSameOrWithin(b, a); }
function validateWorkDirectory(root, requested) {
  ensurePrivateDir(privateBase());
  const workDir = fs.realpathSync(path.resolve(requested));
  if (!fs.statSync(workDir).isDirectory()) throw new Error('工作目录必须是现有目录。');
  const home = fs.realpathSync(os.homedir()), usb = fs.realpathSync(root), privateRoot = fs.realpathSync(privateBase());
  if (workDir === home || home.startsWith(workDir.endsWith(path.sep) ? workDir : workDir + path.sep)) throw new Error('不能把用户主目录或其祖先用作 Claude 工作目录。');
  if (pathsOverlap(workDir, privateRoot)) throw new Error('不能把本机私有运行时根目录、其父目录或子目录用作工作目录。');
  if (workDir === usb || usb.startsWith(workDir.endsWith(path.sep) ? workDir : workDir + path.sep)) throw new Error('不能把 U 盘根目录或其祖先用作工作目录。');
  for (const name of ['config', 'runtime', 'scripts', 'harness', 'sessions']) {
    const reserved = path.join(usb, name);
    if (fs.existsSync(reserved) && isSameOrWithin(workDir, fs.realpathSync(reserved))) throw new Error(`不能把 U 盘 ${name} 运行数据目录及其子目录用作工作目录。`);
  }
  return workDir;
}
async function getWorkDir(root) {
  let dir = await ask(`工作目录 [${process.cwd()}]: `);
  if (!dir) dir = process.cwd();
  dir = path.resolve(dir.replace(/^~(?=$|[\\/])/, os.homedir()));
  return validateWorkDirectory(root, dir);
}
async function createPrivateSession(root, kind = 'claude') {
  const base = privateBase(); assertNoLinks(base); await fsp.mkdir(base, { recursive: true, mode: 0o700 }); ensurePrivateDir(base);
  const id = `linux-${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2, 8)}`;
  const dir = path.join(base, id); await fsp.mkdir(dir, { mode: 0o700 });
  const record = { id, root, dir, identity: usbIdentity(root), children: new Set(), closed: false, opened: null, timer: null, kind, writerLease: null };
  sessions.set(id, record); return record;
}

async function gateSandboxUserns(record, runtime, hooks = {}) {
  const api = hooks.usernsApi || usernsApi;
  if (!api || typeof api.ensureSandboxUserns !== 'function') throw new Error('Linux AppArmor user namespace capability gate is unavailable.');
  try {
    const result = await api.ensureSandboxUserns(runtime, { ask: hooks.ask || ask });
    record.usernsAuthorization = result?.authorization || null;
    return result;
  } catch (error) {
    if (error?.usernsAuthorization) record.usernsAuthorization = error.usernsAuthorization;
    const marker = path.join(record.dir, '.apparmor-cleanup-unconfirmed');
    if (error?.usernsUncertain || error?.usernsAuthorization || fs.existsSync(marker)) {
      record.usernsCleanupUncertain = true;
      record.authorizationCleanupError = error;
    }
    throw error;
  }
}

function assertOwnedRegularTree(root, target) {
  const resolvedRoot = path.resolve(root), resolved = path.resolve(target);
  if (resolved !== resolvedRoot && !resolved.startsWith(`${resolvedRoot}${path.sep}`)) throw new Error('Snapshot path escaped its private validation directory.');
  let cur = resolvedRoot;
  assertNoLinks(cur);
  for (const part of path.relative(cur, path.dirname(resolved)).split(path.sep).filter(Boolean)) {
    cur = path.join(cur, part);
    try {
      const st = fs.lstatSync(cur);
      if (!st.isDirectory() || st.isSymbolicLink() || (process.getuid && st.uid !== process.getuid())) throw new Error('Snapshot validation contains an unsafe path.');
    } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  assertNoLinks(resolved);
}

// restoreSnapshot intentionally only accepts an empty destination. Keep that
// encrypted-store invariant and validate into a throwaway child, then merge a
// narrow set of already-decrypted configuration files into the staged runtime.
async function restoreSessionSnapshot(snapshot, record) {
  const temp = path.join(record.dir, `.snapshot-validate-${crypto.randomBytes(8).toString('hex')}`);
  await fsp.mkdir(temp, { mode: 0o700 });
  try {
    store.restoreSnapshot(snapshot, temp);
    const prefixes = ['config/cc-switch/home/.cc-switch/', 'harness/cc-switch/'];
    const copyFile = (source, destination, root) => {
      assertOwnedRegularTree(temp, source);
      const st = fs.lstatSync(source);
      if (!st.isFile() || st.isSymbolicLink() || (process.getuid && st.uid !== process.getuid())) throw new Error('Snapshot contains an unsafe non-regular file.');
      assertOwnedRegularTree(root, destination);
      const relative = path.relative(root, destination);
      let parent = root;
      for (const component of path.dirname(relative).split(path.sep).filter(Boolean)) {
        parent = path.join(parent, component);
        try { fs.mkdirSync(parent, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
        const pst = fs.lstatSync(parent);
        if (!pst.isDirectory() || pst.isSymbolicLink() || (process.getuid && pst.uid !== process.getuid())) throw new Error('Snapshot destination contains an unsafe directory.');
      }
      assertNoLinks(destination);
      const input = fs.openSync(source, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
      let output;
      try {
        output = fs.openSync(destination, 'wx', 0o600);
        const bytes = fs.readFileSync(input);
        fs.writeFileSync(output, bytes); fs.fsyncSync(output);
      } finally { fs.closeSync(input); if (output !== undefined) fs.closeSync(output); }
    };
    for (const prefix of prefixes) {
      const sourceBase = path.join(temp, ...prefix.slice(0, -1).split('/'));
      if (!fs.existsSync(sourceBase)) continue;
      const todo = [sourceBase];
      while (todo.length) {
        const current = todo.pop(); assertNoLinks(current);
        for (const ent of fs.readdirSync(current, { withFileTypes: true })) {
          const source = path.join(current, ent.name); assertNoLinks(source);
          if (ent.isSymbolicLink()) throw new Error('Snapshot contains a symbolic link.');
          if (ent.isDirectory()) todo.push(source);
          else if (ent.isFile()) {
            const rel = path.relative(temp, source);
            const destination = path.join(record.dir, ...rel.split(path.sep));
            const destinationRoot = path.join(record.dir, ...prefix.slice(0, -1).split('/'));
            copyFile(source, destination, destinationRoot);
          } else throw new Error('Snapshot contains an unsupported filesystem object.');
        }
      }
    }
  } finally { await fsp.rm(temp, { recursive: true, force: true }); }
}

function normalizeHistoryPath(p) {
  if (typeof p !== 'string' || p.startsWith('/') || p.includes('\\') || p.includes('\0')) throw new Error('Claude history contains an unsafe relative path.');
  const parts = p.split('/');
  if (!parts.length || !['projects', 'todos'].includes(parts[0]) || parts.some((x) => !x || x === '.' || x === '..')) throw new Error('Claude history path is outside the archive allowlist.');
  return parts.join('/');
}
function captureClaudeHistory(configDir) {
  const base = configDir, files = [];
  let total = 0;
  for (const tree of ['projects', 'todos']) {
    const start = path.join(base, tree); if (!fs.existsSync(start)) continue;
    assertNoLinks(start); const stack = [[start, tree]];
    while (stack.length) {
      const [dir, relative] = stack.pop();
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, ent.name); assertNoLinks(full);
        if (ent.isSymbolicLink()) throw new Error('Claude history contains a symbolic link.');
        const rel = normalizeHistoryPath(`${relative}/${ent.name}`);
        if (ent.isDirectory()) stack.push([full, rel]);
        else if (ent.isFile()) {
          const data = fs.readFileSync(full); total += data.length;
          if (total > 180 * 1024 * 1024 || files.length >= 2048) throw new Error('Claude history exceeds archive limits.');
          files.push({ path: rel, data: data.toString('base64') });
        } else throw new Error('Claude history contains an unsupported filesystem object.');
      }
    }
  }
  return files;
}
function validateHistoryPayload(bytes, expectedHash) {
  const doc = JSON.parse(Buffer.from(bytes).toString('utf8'));
  if (doc.version !== 1 || doc.workDirHash !== expectedHash || !Array.isArray(doc.files) || doc.files.length > 2048) throw new Error('Encrypted Claude history archive has invalid metadata.');
  const files = new Map(); let total = 0;
  for (const f of doc.files) {
    const rel = normalizeHistoryPath(f.path); if (files.has(rel)) throw new Error('Claude history archive contains duplicate paths.');
    const data = Buffer.from(f.data || '', 'base64'); total += data.length; if (total > 180 * 1024 * 1024) throw new Error('Claude history archive exceeds limits.'); files.set(rel, data);
  }
  return files;
}
function historyWorkHash(workDir) { return crypto.createHash('sha256').update(fs.realpathSync(workDir)).digest('hex'); }
function latestClaudeHistory(root, workHash, opened) {
  const dir = path.join(root, 'sessions', 'linux', 'claude', workHash);
  if (!fs.existsSync(dir)) return new Map();
  assertNoLinks(dir); const names = fs.readdirSync(dir).filter((n) => /^[A-Za-z0-9-]+\.enc$/.test(n)).sort();
  if (names.length > 512) throw new Error('Claude history archive count exceeds limits.');
  const merged = new Map(); let total = 0;
  for (const name of names) {
    const envelope = readRegularFileBounded(path.join(dir, name), 360 * 1024 * 1024, 'Claude history archive');
    total += envelope.length; if (total > 1024 * 1024 * 1024) throw new Error('Claude history archive collection exceeds limits.');
    const files = validateHistoryPayload(store.openArchive(opened, envelope, { kind: 'claude-session-archive' }), workHash);
    for (const [file, data] of files) merged.set(file, data);
  }
  return merged;
}
function archivePayload(workHash, files) {
  return Buffer.from(JSON.stringify({ version: 1, workDirHash: workHash, files: [...files].map(([name, data]) => ({ path: name, data: data.toString('base64') })) }), 'utf8');
}
function writeClaudeArchive(root, workHash, record, incoming) {
  if (!incoming.size) return false;
  // Every run is an immutable encrypted delta. Readers union all verified
  // archives, so concurrent independent windows cannot erase one another.
  const payload = archivePayload(workHash, incoming);
  const envelope = store.sealArchive(record.opened, payload, { kind: 'claude-session-archive' });
  const verified = store.openArchive(record.opened, envelope, { kind: 'claude-session-archive' });
  if (!verified.equals(payload)) throw new Error('Claude history encrypted archive verification failed.');
  const dir = path.join(record.root, 'sessions', 'linux', 'claude', workHash); assertNoLinks(path.dirname(dir)); fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); assertNoLinks(dir);
  const destination = path.join(dir, `${record.id}.enc`); atomicWrite(destination, envelope);
  return true;
}
function savePrivateRecovery(record, kind, sealedArchive, destination, baseRevision) {
  const recoveryDir = ensurePrivateDir(path.join(privateBase(), 'recovery'));
  const item = { version: 1, kind, root: record.root, volume: volumeIdentity(record.identity), destination, baseRevision: baseRevision || null,
    keyring: record.opened.keyringBytes.toString('base64'), archive: sealedArchive.toString('base64') };
  const file = path.join(recoveryDir, `${record.id}.recovery.json`);
  atomicWrite(file, Buffer.from(JSON.stringify(item), 'utf8')); return file;
}
async function createPrivateRecovery(record) {
  if (!record.opened?.dataKey) throw new Error('encrypted session key is unavailable');
  if (record.kind === 'claude') {
    const delta = changedClaudeHistory(record);
    if (!delta.size) return null;
    const payload = archivePayload(record.workHash, delta);
    const encrypted = store.sealArchive(record.opened, payload, { kind: 'claude-session-archive' });
    return savePrivateRecovery(record, 'claude-session-archive', encrypted, `sessions/linux/claude/${record.workHash}/${record.id}.enc`, record.opened.revision);
  }
  if (record.kind === 'cc-switch') {
    const map = await store.captureTree(record.dir); if (!map.size) return null;
    const settingsKey = 'config/cc-switch/home/.cc-switch/settings.json';
    if (map.has(settingsKey)) {
      const original = record.originalSnapshot?.get(settingsKey), before = original ? JSON.parse(original.toString('utf8')) : {};
      const after = JSON.parse(map.get(settingsKey).toString('utf8')); restorePortablePathSettings(before, after);
      map.set(settingsKey, Buffer.from(JSON.stringify(after), 'utf8'));
    }
    const payload = Buffer.from(JSON.stringify({ version: 1, revision: record.opened.revision, files: [...map].map(([name, data]) => ({ path: name, data: data.toString('base64') })) }), 'utf8');
    const encrypted = store.sealArchive(record.opened, payload, { kind: 'linux-config-recovery' });
    return savePrivateRecovery(record, 'linux-config-recovery', encrypted, null, record.opened.revision);
  }
  return null;
}

async function recoverPrivateBundles(root) {
  const dir = path.join(privateBase(), 'recovery');
  if (!fs.existsSync(dir)) { console.log('没有待恢复的本机加密会话。'); return; }
  ensurePrivateDir(dir); const files = fs.readdirSync(dir).filter((name) => /^[A-Za-z0-9-]+\.recovery\.json$/.test(name));
  if (!files.length) { console.log('没有待恢复的本机加密会话。'); return; }
  usbIdentity(root); let restored = 0;
  for (const name of files) {
    const file = path.join(dir, name); assertNoLinks(file);
    const bundle = JSON.parse(readRegularFileBounded(file, 450 * 1024 * 1024, 'Local encrypted recovery bundle').toString('utf8'));
    if (bundle.version !== 1 || !['claude-session-archive', 'linux-config-recovery'].includes(bundle.kind)) throw new Error(`本机恢复包格式无效：${name}`);
    const answer = await ask(`发现本机加密恢复包 ${name}。输入 RESTORE 恢复到已连接的原 U 盘：`);
    if (answer !== 'RESTORE') continue;
    try {
      let done = false;
      for (let attempt = 0; attempt < 3 && !done; attempt++) {
        const password = await askSecret(`输入恢复包对应的主密码（${attempt + 1}/3）`);
        try { await restorePrivateBundle(root, file, password); done = true; }
        catch (e) {
          if (e.message === '恢复密码不正确，或本机恢复包已损坏。' && attempt < 2) { console.log('密码不正确或恢复包无效，请重试。'); continue; }
          throw e;
        }
      }
      if (done) { restored++; console.log(`${name} 已恢复并通过加密校验。`); }
    } catch (e) { console.error(`${name} 尚未恢复，原加密副本已保留：${e.message}`); }
  }
  console.log(`已恢复 ${restored} 个本机加密会话；未完成的恢复包仍保留在 ${dir}。`);
}

async function restorePrivateBundle(root, file, password) {
  usbIdentity(root); assertNoLinks(file);
  const bundle = JSON.parse(readRegularFileBounded(file, 450 * 1024 * 1024, 'Local encrypted recovery bundle').toString('utf8'));
  if (bundle.version !== 1 || !['claude-session-archive', 'linux-config-recovery'].includes(bundle.kind)) throw new Error('本机恢复包格式无效。');
  const tempRoot = await fsp.mkdtemp(path.join(privateBase(), 'recovery-key-'));
  let keySession = null, targetSession = null, lease = null;
  try {
    const keyFile = path.join(tempRoot, 'config', 'cc-switch', 'secure-store', 'keyring.vault.json');
    ensurePrivateDir(path.dirname(keyFile));
    const wrapped = Buffer.from(bundle.keyring || '', 'base64');
    if (!wrapped.length || wrapped.length > 50 * 1024 * 1024) throw new Error('wrapped keyring is missing or oversized');
    fs.writeFileSync(keyFile, wrapped, { mode: 0o600, flag: 'wx' });
    try { keySession = store.openStore(tempRoot, password); } catch { throw new Error('恢复密码不正确，或本机恢复包已损坏。'); }
    const encrypted = Buffer.from(bundle.archive || '', 'base64');
    const plain = store.openArchive(keySession, encrypted, { kind: bundle.kind });
    targetSession = store.openStore(root, password);
    if (!crypto.timingSafeEqual(keySession.dataKey, targetSession.dataKey)) throw new Error('本机恢复包与当前 U 盘的数据密钥不匹配。');
    if (bundle.kind === 'claude-session-archive') {
      const match = /^sessions\/linux\/claude\/[0-9a-f]{64}\/[A-Za-z0-9-]+\.enc$/.test(bundle.destination || '');
      if (!match) throw new Error('Claude archive destination is invalid.');
      const workHash = bundle.destination.split('/')[3]; validateHistoryPayload(plain, workHash);
      const target = path.join(root, ...bundle.destination.split('/'));
      assertNoLinks(path.dirname(target)); fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
      if (fs.existsSync(target)) throw new Error('Claude archive already exists; preserved both versions.');
      atomicWrite(target, encrypted);
      if (!store.openArchive(targetSession, fs.readFileSync(target), { kind: bundle.kind }).equals(plain)) throw new Error('Claude archive verification failed after copying to USB.');
    } else {
      if (store.storeStatus(root).currentRevision !== bundle.baseRevision) throw new Error('CC Switch changed since this recovery was created. Refusing to overwrite the newer provider snapshot.');
      const payload = JSON.parse(plain.toString('utf8'));
      if (payload.version !== 1 || payload.revision !== bundle.baseRevision || !Array.isArray(payload.files)) throw new Error('CC Switch recovery payload is invalid.');
      const map = new Map(payload.files.map((f) => [f.path, Buffer.from(f.data, 'base64')]));
      lease = acquireWriterLease(root);
      store.saveSnapshot(targetSession, map);
    }
    fs.unlinkSync(file);
  } finally {
    releaseWriterLease(lease);
    if (keySession) keySession.close(); if (targetSession) targetSession.close();
    await fsp.rm(tempRoot, { recursive: true, force: true });
  }
}

async function recoverOrphanSession(root, sessionDir, password) {
  assertNoLinks(sessionDir); ensurePrivateDir(sessionDir);
  const metadataFile = path.join(sessionDir, '.portable-session.json'); assertNoLinks(metadataFile);
  const meta = JSON.parse(readRegularFileBounded(metadataFile, 80 * 1024 * 1024, 'Private session recovery metadata').toString('utf8'));
  if (meta.version !== 1 || !/^linux-[A-Za-z0-9-]+$/.test(meta.id || '') || !['claude', 'cc-switch'].includes(meta.kind) || !/^[0-9a-f]{64}$/.test(meta.workHash || '') && meta.kind === 'claude') throw new Error('Abandoned private session metadata is invalid.');
  const live = meta.owner?.bootId === bootId() && processStartTime(Number(meta.owner.pid)) === meta.owner.start;
  if (live) throw new Error('Private session still belongs to a live toolbox process.');
  for (const child of meta.children || []) {
    if (!sameProcessIdentity(child) || child.pgid !== child.pid) continue;
    try { process.kill(-Number(child.pgid), 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
    const end = Date.now() + 2000;
    while (Date.now() < end && sameProcessIdentity(child)) { try { process.kill(-Number(child.pgid), 0); await new Promise((resolve) => setTimeout(resolve, 100)); } catch (e) { if (e.code === 'ESRCH') break; throw e; } }
    if (sameProcessIdentity(child)) { try { process.kill(-Number(child.pgid), 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; } }
  }
  const tempRoot = await fsp.mkdtemp(path.join(privateBase(), 'recovery-key-'));
  let opened = null, target = null;
  try {
    const keyFile = path.join(tempRoot, 'config', 'cc-switch', 'secure-store', 'keyring.vault.json');
    ensurePrivateDir(path.dirname(keyFile));
    const keyring = Buffer.from(meta.keyring || '', 'base64');
    if (!keyring.length || keyring.length > 50 * 1024 * 1024) throw new Error('Crash recovery keyring is missing or oversized.');
    fs.writeFileSync(keyFile, keyring, { flag: 'wx', mode: 0o600 });
    try { opened = store.openStore(tempRoot, password); } catch { throw new Error('恢复密码不正确，或本机残留会话已损坏。'); }
    opened.revision = meta.revision || null;
    const record = { id: meta.id, root, dir: sessionDir, kind: meta.kind, identity: { dev: meta.volume?.dev || 'unknown', mountSource: meta.volume?.source || '' }, opened, workHash: meta.workHash, children: new Set(), closed: true };
    if (meta.kind === 'claude') {
      record.claudeConfigDir = path.join(sessionDir, 'harness', 'cc-switch', 'claude');
      record.initialHistory = new Map();
    } else {
      try {
        target = store.openStore(root, password);
        if (crypto.timingSafeEqual(opened.dataKey, target.dataKey)) record.originalSnapshot = store.readSnapshot(target);
      } catch { /* The wrapped key still permits an authenticated local archive; exact USB revision is checked on later import. */ }
    }
    const recovery = await createPrivateRecovery(record);
    if (!recovery) throw new Error('Abandoned session has no supported recoverable files; plaintext was preserved for manual recovery.');
    await fsp.rm(sessionDir, { recursive: true, force: true });
    sessions.delete(meta.id);
    return recovery;
  } finally {
    if (opened) opened.close(); if (target) target.close();
    await fsp.rm(tempRoot, { recursive: true, force: true });
  }
}

async function recoverOrphanSessions(root) {
  const base = privateBase(); if (!fs.existsSync(base)) return;
  ensurePrivateDir(base);
  for (const name of fs.readdirSync(base)) {
    if (!/^linux-[A-Za-z0-9-]+$/.test(name)) continue;
    const sessionDir = path.join(base, name); assertNoLinks(sessionDir);
    if (!fs.lstatSync(sessionDir).isDirectory()) continue;
    const metadata = path.join(sessionDir, '.portable-session.json');
    if (!fs.existsSync(metadata)) { console.error(`发现缺少安全恢复元数据的本机隔离目录，未读取或删除：${sessionDir}`); continue; }
    let meta;
    try { assertNoLinks(metadata); meta = JSON.parse(readRegularFileBounded(metadata, 80 * 1024 * 1024, 'Private session recovery metadata').toString('utf8')); }
    catch (e) { console.error(`本机隔离会话元数据无效，保留目录：${sessionDir}；${e.message}`); continue; }
    if (meta.owner?.bootId === bootId() && processStartTime(Number(meta.owner.pid)) === meta.owner.start) continue;
    if (!process.stdin.isTTY) { console.error(`发现异常退出遗留的本机隔离目录；非交互运行不会解锁或删除它：${sessionDir}`); continue; }
    const confirm = await ask(`发现异常退出遗留的隔离会话。输入 ENCRYPT 将其加密转入恢复队列：`);
    if (confirm !== 'ENCRYPT') { console.log(`已保留本机隔离目录：${sessionDir}`); continue; }
    let recovered = false;
    for (let attempt = 0; attempt < 3 && !recovered; attempt++) {
      const password = await askSecret(`输入会话对应的主密码（${attempt + 1}/3）`);
      try { const file = await recoverOrphanSession(root, sessionDir, password); console.log(`异常会话已加密保存到本机恢复队列：${file}`); recovered = true; }
      catch (e) {
        if (/恢复密码不正确/.test(e.message) && attempt < 2) { console.log('密码不正确或恢复资料无效，请重试。'); continue; }
        console.error(`未能安全加密遗留会话，完整保留原目录：${sessionDir}；${e.message}`); break;
      }
    }
  }
}

function processStartTime(pid) {
  try { const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'); return stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/)[19]; } catch { return null; }
}

function processIdentity(pid) {
  const raw = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'), fields = raw.slice(raw.lastIndexOf(')') + 2).trim().split(/\s+/);
  const start = fields[19], pgid = Number(fields[2]);
  if (!/^\d+$/.test(start || '') || !Number.isSafeInteger(pgid) || pgid < 1) throw new Error('process identity is unavailable');
  return { pid: Number(pid), start, pgid, bootId: bootId() };
}
function sameProcessIdentity(owner) {
  try {
    return owner?.bootId === bootId() && Number.isSafeInteger(Number(owner.pid)) && Number(owner.pid) === Number(owner.pgid) &&
      processStartTime(Number(owner.pid)) === owner.start && processIdentity(Number(owner.pid)).pgid === Number(owner.pgid);
  } catch { return false; }
}
function bootId() { try { return fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim(); } catch { return 'unknown'; } }
function brokerPaths(root) {
  const id = crypto.createHash('sha256').update(fs.realpathSync(root)).digest('hex').slice(0, 20);
  const dir = ensurePrivateDir(path.join(privateBase(), 'brokers'));
  return { id, dir, socket: path.join(dir, `${id}.sock`), locator: path.join(dir, `${id}.json`) };
}
function providerFromLocalSession(record) {
  const settings = path.join(record.dir, 'harness', 'cc-switch', 'claude', 'settings.json');
  if (!fs.existsSync(settings)) throw new Error('CC Switch has not selected a Claude provider yet.');
  assertNoLinks(settings);
  return store.providerFromSnapshot(new Map([['harness/cc-switch/claude/settings.json', fs.readFileSync(settings)]]));
}
async function startProviderBroker(root, record) {
  const paths = brokerPaths(root); assertNoLinks(paths.socket); assertNoLinks(paths.locator);
  try { fs.unlinkSync(paths.socket); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const token = crypto.randomBytes(32).toString('hex');
  const server = net.createServer(async (socket) => {
    socket.setTimeout(2000); let input = '';
    socket.on('data', async (chunk) => {
      input += chunk.toString('utf8');
      if (input.length > 4096) { socket.destroy(); return; }
      if (!input.includes('\n')) return;
      let req; try { req = JSON.parse(input.slice(0, input.indexOf('\n'))); } catch { socket.end('{"error":"bad request"}\n'); return; }
      const a = Buffer.from(String(req.token || ''), 'utf8'), b = Buffer.from(token, 'utf8');
      if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) { socket.end('{"error":"unauthorized"}\n'); return; }
      if (req.action === 'lock') {
        if (record.kind !== 'cc-switch' || record.closed || record.lockRequested) { socket.end('{"error":"not-active"}\n'); return; }
        record.lockRequested = true;
        socket.end('{"accepted":true}\n');
        setImmediate(() => { void saveAndRemove(record); });
        return;
      }
      if (req.action) { socket.end('{"error":"unsupported-action"}\n'); return; }
      try {
        const provider = providerFromLocalSession(record);
        const exposed = provider.mode === 'proxy-managed'
          ? await nativeProviderForManager(record, provider)
          : provider;
        socket.end(`${JSON.stringify({ provider: exposed })}\n`);
      }
      catch (e) { socket.end(`${JSON.stringify({ error: e.message })}\n`); }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(paths.socket, resolve); });
  fs.chmodSync(paths.socket, 0o600);
  const metadata = { version: 1, socket: paths.socket, token, pid: process.pid, start: processStartTime(process.pid), bootId: bootId(), volume: volumeIdentity(usbIdentity(root)) };
  atomicWrite(paths.locator, Buffer.from(JSON.stringify(metadata), 'utf8'));
  record.broker = { ...paths, server, token };
  return record.broker;
}
async function nativeProviderForManager(record, provider) {
  if (!record.nativeProxy || !record.managerChild || !nativeProxyApi?.asNativeProvider) throw new Error('CC Switch PROXY_MANAGED provider has no active private Linux proxy.');
  return nativeProxyApi.asNativeProvider(record.nativeProxy, provider, record.managerChild.pid);
}
function stopProviderBroker(broker) {
  if (!broker) return;
  try { broker.server.close(); } catch {}
  try { fs.unlinkSync(broker.socket); } catch {}
  try { if (JSON.parse(fs.readFileSync(broker.locator, 'utf8')).token === broker.token) fs.unlinkSync(broker.locator); } catch {}
}
async function getLiveProvider(root) {
  const paths = brokerPaths(root); if (!fs.existsSync(paths.locator)) return null;
  assertNoLinks(paths.locator); const meta = JSON.parse(fs.readFileSync(paths.locator, 'utf8'));
  if (meta.version !== 1 || meta.bootId !== bootId() || processStartTime(Number(meta.pid)) !== meta.start || meta.volume.dev !== String(usbIdentity(root).dev) || meta.volume.source !== (usbIdentity(root).mountSource || '')) throw new Error('CC Switch provider broker is stale or belongs to another mounted volume.');
  if (meta.socket !== paths.socket || !fs.lstatSync(paths.socket).isSocket()) throw new Error('CC Switch provider broker socket is invalid.');
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(paths.socket); let response = '';
    socket.setTimeout(2500, () => { socket.destroy(); reject(new Error('CC Switch provider broker timed out.')); });
    socket.once('connect', () => socket.write(`${JSON.stringify({ token: meta.token })}\n`));
    socket.on('data', (chunk) => { response += chunk.toString('utf8'); if (response.length > 1024 * 1024) { socket.destroy(); reject(new Error('CC Switch provider response exceeded its limit.')); } if (response.includes('\n')) { socket.end(); try { const data = JSON.parse(response.slice(0, response.indexOf('\n'))); if (data.error) reject(new Error(data.error)); else resolve(data.provider); } catch (e) { reject(e); } } });
    socket.once('error', (e) => reject(new Error(`CC Switch provider broker is unavailable: ${e.message}`)));
  });
}
async function lockActiveManager(root) {
  const resolvedRoot = path.resolve(root);
  const pending = [...sessions.values()].filter((record) => {
    if (record.kind !== 'cc-switch' || path.resolve(record.root) !== resolvedRoot || record.cleaned || record.broker) return false;
    const marker = path.join(record.dir, '.apparmor-cleanup-unconfirmed');
    if (!record.authorizationCleanupError && !record.usernsCleanupUncertain && !fs.existsSync(marker)) return false;
    return stillMounted(root, record.identity);
  });
  if (pending.length) {
    let cleaned = false;
    for (const record of pending) {
      await saveAndRemove(record);
      cleaned ||= !!record.cleaned;
      if (!record.cleaned) {
        const detail = record.authorizationCleanupError?.message || 'temporary AppArmor profile removal is not confirmed';
        throw new Error(`本 U 盘 CC Switch 会话清理仍未完成；私有目录保留在 ${record.dir}。请先解决 AppArmor 临时规则清理，再重试：${detail}`);
      }
    }
    return cleaned;
  }
  const paths = brokerPaths(root);
  if (!fs.existsSync(paths.locator)) return false;
  assertNoLinks(paths.locator);
  const meta = JSON.parse(fs.readFileSync(paths.locator, 'utf8'));
  const identity = usbIdentity(root);
  if (meta.version !== 1 || meta.bootId !== bootId() || processStartTime(Number(meta.pid)) !== meta.start ||
      meta.volume.dev !== String(identity.dev) || meta.volume.source !== (identity.mountSource || '') || meta.socket !== paths.socket) {
    throw new Error('CC Switch broker identity is stale or belongs to another USB volume.');
  }
  if (!fs.existsSync(paths.socket) || !fs.lstatSync(paths.socket).isSocket()) throw new Error('CC Switch broker is unavailable.');
  const ack = await new Promise((resolve, reject) => {
    const socket = net.createConnection(paths.socket); let response = '';
    socket.setTimeout(3000, () => { socket.destroy(); reject(new Error('CC Switch lock request timed out.')); });
    socket.once('connect', () => socket.write(`${JSON.stringify({ token: meta.token, action: 'lock' })}\n`));
    socket.on('data', (chunk) => { response += chunk.toString('utf8'); if (response.length > 4096) { socket.destroy(); reject(new Error('CC Switch lock response exceeded its limit.')); } if (response.includes('\n')) { socket.end(); try { resolve(JSON.parse(response.slice(0, response.indexOf('\n')))); } catch (e) { reject(e); } } });
    socket.once('error', (e) => reject(new Error(`CC Switch broker could not accept lock request: ${e.message}`)));
  });
  if (!ack.accepted) {
    if (ack.error === 'not-active') return false;
    throw new Error(ack.error || 'CC Switch manager rejected the lock request.');
  }
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (!fs.existsSync(paths.locator)) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('CC Switch accepted the lock request but did not finish saving within 30 seconds; its private session remains available for recovery.');
}
function acquireWriterLease(root) {
  const file = path.join(root, 'config', 'cc-switch', 'linux-ui-writer.lock');
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const token = `${process.pid}:${bootId()}:${processStartTime(process.pid) || 'unknown'}:${require('node:crypto').randomBytes(16).toString('hex')}`;
  for (let attempt = 0; attempt < 2; attempt++) {
    try { const fd = fs.openSync(file, 'wx', 0o600); fs.writeFileSync(fd, token); fs.fsyncSync(fd); fs.closeSync(fd); return { file, token }; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      let old = ''; try { old = fs.readFileSync(file, 'utf8'); } catch { continue; }
      const parts = old.split(':');
      if (parts.length !== 4 || !/^\d+$/.test(parts[0]) || !/^[0-9a-f-]{36}$/.test(parts[1]) || !/^\d+$/.test(parts[2]) || !/^[0-9a-f]{32}$/.test(parts[3])) throw new Error('CC Switch writer lock metadata is malformed; refusing to remove it automatically.');
      const [pidText, oldBoot, start] = parts, pid = Number(pidText);
      let alive = false; try { if (Number.isSafeInteger(pid) && pid > 1 && oldBoot === bootId()) { process.kill(pid, 0); alive = processStartTime(pid) === start; } } catch {}
      if (alive) throw new Error('CC Switch 配置正在另一个工具箱窗口中使用；请先关闭该窗口。');
      const check = fs.readFileSync(file, 'utf8');
      if (check !== old) throw new Error('CC Switch writer lock changed during stale-lock validation; retry safely.');
      try { fs.unlinkSync(file); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    }
  }
  throw new Error('无法取得 CC Switch 配置写入锁。');
}
function releaseWriterLease(lease) {
  if (!lease) return;
  try { if (fs.readFileSync(lease.file, 'utf8') === lease.token) fs.unlinkSync(lease.file); } catch {}
}
function installExitHandlers() {
  if (exitHandlersInstalled) return; exitHandlersInstalled = true;
  const stop = async (signal) => {
    if (!shutdownPromise) shutdownPromise = (async () => {
      await Promise.all([...sessions.values()].map(async (record) => { try { await saveAndRemove(record); } catch {} }));
      process.exit(signal === 'SIGINT' ? 130 : signal === 'SIGHUP' ? 129 : 143);
    })();
    return shutdownPromise;
  };
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => { void stop(signal); });
}
function waitForChild(child) {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) { resolve({ code: child.exitCode, signal: child.signalCode }); return; }
    child.once('error', reject);
    child.once('exit', (code, signal) => resolve({ code, signal }));
  });
}
async function awaitSandboxReady(record, child) {
  if (!child?.sandboxReady || typeof child.sandboxReady.then !== 'function') throw new Error('Linux sandbox did not provide a namespace setup readiness signal.');
  await child.sandboxReady;
  record.discard = false;
}
async function stopOwnedProcesses(record) {
  const ownedGroups = [];
  for (const child of record.children) {
    // A ChildProcess object that has already exited must never cause a signal
    // to be sent to a potentially reused PID/process-group id.
    if (child.exitCode !== null || child.signalCode !== null) continue;
    let owner = child.__portableOwner;
    if (!owner) { try { owner = child.__portableOwner = processIdentity(child.pid); } catch { continue; } }
    if (!sameProcessIdentity(owner) || owner.pgid !== owner.pid) continue;
    ownedGroups.push({ child, owner });
    try { process.kill(-owner.pgid, 'SIGTERM'); } catch (e) { if (!['ESRCH'].includes(e.code)) throw e; }
  }
  const deadline = Date.now() + 2500;
  while (Date.now() < deadline) {
    let alive = false;
    for (const { child, owner } of ownedGroups) {
      if (child.exitCode !== null || child.signalCode !== null) continue;
      if (!sameProcessIdentity(owner)) continue;
      try { process.kill(-owner.pgid, 0); alive = true; } catch (e) { if (e.code !== 'ESRCH') throw e; }
    }
    if (!alive) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  for (const { child, owner } of ownedGroups) {
    if (child.exitCode !== null || child.signalCode !== null || !sameProcessIdentity(owner)) continue;
    try { process.kill(-owner.pgid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
  }
  const killDeadline = Date.now() + 1200;
  while (Date.now() < killDeadline) {
    let alive = false;
    for (const { child, owner } of ownedGroups) {
      if (child.exitCode !== null || child.signalCode !== null) continue;
      if (!sameProcessIdentity(owner)) continue;
      try { process.kill(-owner.pgid, 0); alive = true; } catch (e) { if (e.code !== 'ESRCH') throw e; }
    }
    if (!alive) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Owned Linux process group did not terminate; session data was preserved.');
}

async function saveAndRemove(record) {
  if (record.cleanupPromise) return record.cleanupPromise;
  if (record.cleaned) return;
  record.closed = true; clearInterval(record.timer);
  const running = saveAndRemoveInternal(record);
  record.cleanupPromise = running;
  try { await running; }
  finally { record.cleanupPromise = null; if (!record.cleaned) record.closed = false; }
}

async function saveAndRemoveInternal(record) {
  let stopError = null;
  try { await stopOwnedProcesses(record); } catch (e) { stopError = e; console.error(e.message); }
  // Keep a live manager's broker and the exact policy lease untouched when
  // process-group shutdown could not be confirmed. The caller may retry.
  if (stopError) { record.closed = false; return; }
  if (record.broker) { stopProviderBroker(record.broker); record.broker = null; }
  if (record.usernsAuthorization) {
    let releaseConfirmed = false;
    try {
      if (!usernsApi?.releaseSandboxUserns) throw new Error('user namespace authorization release API is unavailable');
      await usernsApi.releaseSandboxUserns(record.usernsAuthorization);
      releaseConfirmed = true;
    }
    catch (e) {
      // The helper can lose its own unload confirmation after the exact
      // profile has already disappeared (including a user's manual unload).
      // Continue only when the kernel profile list positively confirms it is
      // absent; an unreadable list remains an unconfirmed cleanup.
      if (authorizationProfileLoaded(record.usernsAuthorization) === false) releaseConfirmed = true;
      else {
        record.closed = false;
        record.authorizationCleanupError = e;
        console.error(`Linux AppArmor 临时授权释放未确认；会话目录保留在 ${record.dir}，尚未归档或删除。可重试关闭；若需手动卸载，请运行错误中的命令，再重试关闭：${e.message}`);
        return;
      }
    }
    if (releaseConfirmed) {
      record.usernsReleaseConfirmed = true;
      record.usernsAuthorization = null;
      record.authorizationCleanupError = null;
    }
  }
  const uncertainMarker = path.join(record.dir, '.apparmor-cleanup-unconfirmed');
  if (record.usernsCleanupUncertain && !record.usernsAuthorization && !record.usernsReleaseConfirmed) {
    record.closed = false;
    const detail = record.authorizationCleanupError?.message || 'no authorization handle is available to confirm profile removal';
    console.error(`Linux AppArmor 清理仍未确认；保留私有会话目录 ${record.dir}，不会归档或删除。请检查临时 profile 并按需手动卸载后重试：${detail}`);
    return;
  }
  if (fs.existsSync(uncertainMarker)) {
    if (!record.usernsReleaseConfirmed) {
      record.closed = false;
      const detail = record.authorizationCleanupError?.message || 'the unconfirmed AppArmor marker has no matching authorization handle';
      console.error(`Linux AppArmor 清理仍未确认；保留私有会话目录 ${record.dir}，不会归档或删除。请检查临时 profile 并按需手动卸载后重试：${detail}`);
      return;
    }
    try {
      assertNoLinks(uncertainMarker);
      const markerStat = fs.lstatSync(uncertainMarker);
      if (!markerStat.isFile() || markerStat.isSymbolicLink() || (process.getuid && markerStat.uid !== process.getuid())) throw new Error('AppArmor cleanup marker is not an owned regular file.');
      fs.unlinkSync(uncertainMarker);
      record.usernsCleanupUncertain = false;
      record.usernsReleaseConfirmed = false;
    } catch (e) {
      record.closed = false; record.authorizationCleanupError = e;
      console.error(`AppArmor profile 已确认卸载，但无法移除私有清理标记；保留会话目录 ${record.dir} 供重试：${e.message}`);
      return;
    }
  } else if (record.usernsReleaseConfirmed) {
    record.usernsCleanupUncertain = false;
    record.usernsReleaseConfirmed = false;
  }
  if (record.discard) {
    if (record.nativeProxy && nativeProxyApi?.closeNativeProxy) {
      try { await nativeProxyApi.closeNativeProxy(record.nativeProxy); } catch (e) { console.error(`Linux proxy reservation cleanup failed: ${e.message}`); }
      record.nativeProxy = null;
    }
    releaseWriterLease(record.writerLease); record.writerLease = null;
    if (record.opened && typeof record.opened.close === 'function') record.opened.close();
    await fsp.rm(record.dir, { recursive: true, force: true });
    record.cleaned = true; sessions.delete(record.id);
    return;
  }
  if (record.nativeProxy && nativeProxyApi?.restorePortableProxySettings) {
    try { await nativeProxyApi.restorePortableProxySettings(record.nativeProxy); }
    catch (e) { record.closed = false; console.error(`Linux 临时代理端口恢复失败；保留私有会话 ${record.dir}：${e.message}`); return; }
  }
  if (record.kind === 'cc-switch' && record.runtime && runtimeApi.exportClaudeRuntime && stillMounted(record.root, record.identity)) {
    try { await runtimeApi.exportClaudeRuntime(record.root, record.dir); }
    catch (e) { console.error(`Claude Code runtime export failed: ${e.message}`); }
  }
  if (record.nativeProxy && nativeProxyApi?.closeNativeProxy) {
    try { await nativeProxyApi.closeNativeProxy(record.nativeProxy); }
    catch (e) { console.error(`Linux proxy reservation cleanup failed: ${e.message}`); }
    record.nativeProxy = null;
  }
  // Do not remove a live workspace on an unplugged USB: recovery is safer than
  // deleting the only unsaved copy. When mounted, save the latest snapshot.
  if (stillMounted(record.root, record.identity)) {
    try {
      if (record.kind === 'cc-switch') {
        const latest = store.storeStatus(record.root).currentRevision;
        if (latest !== record.opened.revision) throw new Error('Encrypted provider snapshot changed while CC Switch was open. Refusing to overwrite it; recover this private session manually.');
        const map = await store.captureTree(record.dir);
        if (map.size) {
          const settingsKey = 'config/cc-switch/home/.cc-switch/settings.json';
          if (map.has(settingsKey)) {
            const original = record.originalSnapshot?.get(settingsKey);
            const before = original ? JSON.parse(original.toString('utf8')) : {};
            const after = JSON.parse(map.get(settingsKey).toString('utf8'));
            restorePortablePathSettings(before, after); map.set(settingsKey, Buffer.from(JSON.stringify(after), 'utf8'));
          }
          await store.saveSnapshot(record.opened, map);
        }
      } else if (record.kind === 'claude') {
        const delta = changedClaudeHistory(record);
        if (delta.size) writeClaudeArchive(record.root, record.workHash, record, delta);
      }
    } catch (e) {
      try {
        const recovery = await createPrivateRecovery(record);
        if (recovery) {
          releaseWriterLease(record.writerLease);
          if (record.opened) record.opened.close();
          await fsp.rm(record.dir, { recursive: true, force: true }); record.cleaned = true; sessions.delete(record.id);
          console.error(`USB 加密归档未完成；已把会话加密保存在本机恢复区 ${recovery}，并清除明文会话。原因：${e.message}`);
          return;
        }
      } catch (recoveryError) { console.error(`恢复包加密失败，保留唯一会话副本 ${record.dir}：${recoveryError.message}`); return; }
      console.error(`加密归档失败，保留本机会话以便恢复：${record.dir}；原因：${e.message}`); return;
    }
    releaseWriterLease(record.writerLease);
    if (record.opened && typeof record.opened.close === 'function') record.opened.close();
    await fsp.rm(record.dir, { recursive: true, force: true });
    record.cleaned = true; sessions.delete(record.id);
  } else {
    try {
      await createPrivateRecovery(record);
    } catch (e) { console.error(`断盘恢复包创建失败，保留唯一本机副本：${record.dir}；原因：${e.message}`); return; }
    releaseWriterLease(record.writerLease);
    if (record.opened && typeof record.opened.close === 'function') record.opened.close();
    await fsp.rm(record.dir, { recursive: true, force: true });
    record.cleaned = true; sessions.delete(record.id);
    console.error('会话敏感文件已加密留在本机恢复区并从明文会话目录清除；重新连接同一 U 盘后可恢复。');
  }
}

function restorePortablePathSettings(portable, local) {
  const keys = ['claudeConfigDir', 'codexConfigDir', 'geminiConfigDir', 'grokConfigDir', 'opencodeConfigDir', 'openclawConfigDir', 'hermesConfigDir', 'piConfigDir', 'directoryOverrides'];
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(portable, key)) local[key] = portable[key];
    else delete local[key];
  }
}

function localizeCcSwitchSettings(root) {
  const file = path.join(root, 'config', 'cc-switch', 'home', '.cc-switch', 'settings.json');
  assertNoLinks(file);
  const data = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  const fields = { claudeConfigDir: '/config/claude', codexConfigDir: '/harness/cc-switch/codex', geminiConfigDir: '/harness/cc-switch/gemini', grokConfigDir: '/harness/cc-switch/grok', opencodeConfigDir: '/harness/cc-switch/opencode', openclawConfigDir: '/harness/cc-switch/openclaw', hermesConfigDir: '/harness/cc-switch/hermes', piConfigDir: '/harness/cc-switch/pi' };
  Object.assign(data, fields);
  if (Object.prototype.hasOwnProperty.call(data, 'directoryOverrides')) data.directoryOverrides = {};
  atomicWrite(file, Buffer.from(JSON.stringify(data), 'utf8'));
}

function watchForUnplug(record, label) {
  clearInterval(record.timer);
  record.timer = setInterval(() => {
    if (!stillMounted(record.root, record.identity)) {
      console.error(`检测到 U 盘已断开；正在停止${label}并保留加密恢复副本。`);
      void saveAndRemove(record);
    }
  }, 1200);
  record.timer.unref();
}

async function startClaude(root, workDir) {
  installExitHandlers();
  workDir = validateWorkDirectory(root, workDir);
  const record = await createPrivateSession(root, 'claude'); record.discard = true;
  try {
    const runtime = await runtimeApi.stageRuntime(root, record.dir);
    await gateSandboxUserns(record, runtime);
    const opened = await unlock(root, false); record.opened = opened;
    const snapshot = await store.readSnapshot(opened);
    const liveProvider = await getLiveProvider(root);
    if (!snapshot.size && !liveProvider) throw new Error('加密存储还没有 CC Switch 快照；请先打开 CC Switch 并选择供应商。');
    const provider = liveProvider || store.providerFromSnapshot(snapshot);
    if (provider.mode === 'proxy-managed') throw new Error('当前供应商使用 PROXY_MANAGED；需要先打开此 U 盘上的 CC Switch 并启动其 Linux 私有代理。');
    if (provider.mode === 'managed-native-proxy' && !liveProvider) throw new Error('拒绝使用快照中旧的本机代理地址；请打开此 U 盘上的 CC Switch 后重试。');
    if (snapshot.size) await restoreSessionSnapshot(snapshot, record);
    record.originalSnapshot = snapshot; record.claudeConfigDir = runtime.claudeConfig; record.workHash = historyWorkHash(workDir); writePrivateOwner(record);
    record.initialHistory = restoreLatestClaudeHistory(root, record, runtime.claudeConfig);
    scrubClaudeSettings(runtime.claudeConfig);
    const environment = { ANTHROPIC_BASE_URL: provider.baseUrl, [provider.authEnvironmentName]: provider.secret };
    for (const [key, value] of Object.entries(provider.models || {})) environment[key] = String(value);
    const cfg = sandboxApi.buildSandbox({ sessionRoot: record.dir, runtime, mode: 'claude', command: runtime.claude, args: [], workDir, network: true, extraEnv: environment });
    const child = sandboxApi.launchSandbox(cfg, { trackSetup: true });
    if (!child || typeof child.pid !== 'number') throw new Error('Linux sandbox did not return an owned child process.');
    child.__owned = true; record.children.add(child); writePrivateOwner(record);
    await awaitSandboxReady(record, child);
    watchForUnplug(record, '此会话');
    const result = await waitForChild(child);
    if (result.code !== 0) console.error(`Claude Code 已退出（${result.signal ? `signal ${result.signal}` : `exit ${result.code}`}）；已保存该会话中完成的加密历史。`);
  } finally { await saveAndRemove(record); }
}

async function runCcSwitch(root, network) {
  installExitHandlers();
  const record = await createPrivateSession(root, 'cc-switch'); record.discard = true;
  try {
    const runtime = await runtimeApi.stageRuntime(root, record.dir);
    await gateSandboxUserns(record, runtime);
    const opened = await unlock(root, true); record.opened = opened;
    record.writerLease = acquireWriterLease(root);
    record.originalSnapshot = await store.readSnapshot(opened);
    if (record.originalSnapshot.size) await restoreSessionSnapshot(record.originalSnapshot, record);
    writePrivateOwner(record);
    localizeCcSwitchSettings(record.dir);
    record.runtime = runtime;
    for (const name of ['codex', 'gemini', 'grok', 'opencode', 'openclaw', 'hermes', 'pi']) { const dir = path.join(runtime.ccConfig, name); fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); assertNoLinks(dir); }
    record.broker = await startProviderBroker(root, record);
    if (nativeProxyApi?.prepareNativeProxy) record.nativeProxy = await nativeProxyApi.prepareNativeProxy({ sessionRoot: record.dir, network });
    const cfg = sandboxApi.buildSandbox({ sessionRoot: record.dir, runtime, mode: 'cc-switch', command: runtime.ccSwitch, args: [], workDir: runtime.workDir, network });
    if (record.nativeProxy && nativeProxyApi?.releaseReservation) await nativeProxyApi.releaseReservation(record.nativeProxy);
    const child = sandboxApi.launchSandbox(cfg, { trackSetup: true }); if (!child || typeof child.pid !== 'number') throw new Error('Sandbox did not return an owned process.');
    record.managerChild = child; record.children.add(child); writePrivateOwner(record);
    await awaitSandboxReady(record, child);
    if (record.nativeProxy && nativeProxyApi?.attachManager) nativeProxyApi.attachManager(record.nativeProxy, child.pid);
    watchForUnplug(record, 'CC Switch');
    const result = await waitForChild(child);
    if (result.code !== 0) console.error(`CC Switch 已退出（${result.signal ? `signal ${result.signal}` : `exit ${result.code}`}）；已保存会话中的加密配置。`);
  } finally { await saveAndRemove(record); }
}

function restoreLatestClaudeHistory(root, record, configDir) {
  const files = latestClaudeHistory(root, record.workHash, record.opened), base = configDir;
  for (const [relative, data] of files) {
    const target = path.resolve(base, ...relative.split('/'));
    if (!target.startsWith(base + path.sep)) throw new Error('Claude history restore escaped its private HOME.');
    assertNoLinks(path.dirname(target)); fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 }); assertNoLinks(path.dirname(target));
    if (fs.existsSync(target)) throw new Error('Claude history restore target already exists in the private session.');
    const fd = fs.openSync(target, 'wx', 0o600); try { fs.writeFileSync(fd, data); } finally { fs.closeSync(fd); }
  }
  return files;
}
function changedClaudeHistory(record) {
  const initial = record.initialHistory || new Map(), changed = new Map();
  if (!record.claudeConfigDir) return changed;
  for (const file of captureClaudeHistory(record.claudeConfigDir)) {
    const data = Buffer.from(file.data, 'base64'), previous = initial.get(file.path);
    if (!previous || !previous.equals(data)) changed.set(file.path, data);
  }
  return changed;
}
function scrubClaudeSettings(configDir) {
  const file = path.join(configDir, 'settings.json');
  const doc = fs.existsSync(file) ? (assertNoLinks(file), JSON.parse(fs.readFileSync(file, 'utf8'))) : {};
  const env = doc.env && typeof doc.env === 'object' ? doc.env : {};
  // Provider values only enter the isolated launch environment (FD 3). Claude
  // may let settings.env override process env, so strip all shared values.
  for (const key of ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_MODEL', 'ANTHROPIC_REASONING_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL']) delete env[key];
  doc.env = env; atomicWrite(file, Buffer.from(JSON.stringify(doc), 'utf8'));
}

async function testProvider(provider) {
  if (!provider || provider.mode === 'proxy-managed') throw new Error('当前供应商为 PROXY_MANAGED；请先打开本 U 盘的 CC Switch 私有代理。');
  const url = new URL(provider.baseUrl);
  const managed = provider.mode === 'managed-native-proxy';
  const loopback = /^(localhost|127\.0\.0\.1|\[::1\])$/i.test(url.hostname);
  if (url.username || url.password || (managed ? (url.protocol !== 'http:' || !loopback) : (url.protocol !== 'https:' || loopback))) throw new Error('直连测试仅允许 HTTPS；受控代理测试仅允许经活动管理器认证的 loopback HTTP。');
  const model = provider.models?.ANTHROPIC_MODEL || provider.models?.ANTHROPIC_DEFAULT_SONNET_MODEL || 'claude-3-5-haiku-latest';
  // Preserve provider path prefixes (for example /gateway/v1) while avoiding
  // duplicating /v1 when the configured URL already includes it.
  const basePath = url.pathname.replace(/\/+$/, '');
  const apiPath = /(?:^|\/)v1$/i.test(basePath) ? `${basePath}/messages` : `${basePath}/v1/messages`;
  const endpoint = new URL(apiPath || '/v1/messages', url.origin);
  const body = Buffer.from(JSON.stringify({ model, max_tokens: 1, messages: [{ role: 'user', content: 'Reply with OK.' }] }), 'utf8');
  const headers = { 'content-type': 'application/json', 'content-length': String(body.length), 'anthropic-version': '2023-06-01' };
  if (provider.authEnvironmentName === 'ANTHROPIC_AUTH_TOKEN') headers.authorization = `Bearer ${provider.secret}`;
  else headers['x-api-key'] = provider.secret;
  const transport = managed ? require('node:http') : https;
  await new Promise((resolve, reject) => {
    const req = transport.request(endpoint, { method: 'POST', headers, timeout: 20000 }, (res) => {
      res.resume(); res.once('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) { console.log(`连接测试成功（HTTP ${res.statusCode}，模型 ${model}）；未显示回复内容。`); resolve(); }
        else reject(new Error(`供应商返回 HTTP ${res.statusCode}；未显示响应内容。`));
      });
    });
    req.once('timeout', () => req.destroy(new Error('供应商连接超时。')));
    req.once('error', (e) => reject(new Error(`连接测试失败：${e.message}`)));
    req.end(body);
  });
}

async function showStatus(root) {
  const enc = store.storeStatus(root), runtime = await runtimeApi.status(root);
  console.log(`加密供应商配置：${enc.state}${enc.revision ? `（修订 ${enc.revision}）` : ''}`);
  console.log(`盘内运行时：${runtime.ready ? '已就绪' : '尚未就绪'}（${runtime.arch || 'unknown'}）`);
  for (const item of runtime.missing || []) console.log(`  缺少：${item}`);
  const recoveryDir = path.join(privateBase(), 'recovery');
  const pending = fs.existsSync(recoveryDir) ? fs.readdirSync(recoveryDir).filter((n) => n.endsWith('.recovery.json')).length : 0;
  console.log(`本机待恢复的加密会话：${pending}`);
  console.log(`Linux 会话数：${sessions.size}`);
  const readSysctl = (file, boolean = false) => {
    try { const value = fs.readFileSync(file, 'utf8').trim(); return (boolean ? /^(0|1)$/.test(value) : /^\d+$/.test(value)) ? value : null; }
    catch { return null; }
  };
  console.log(`内核命名空间限制值（事实读取）：unprivileged_userns_clone=${readSysctl('/proc/sys/kernel/unprivileged_userns_clone', true)} apparmor_restrict_unprivileged_userns=${readSysctl('/proc/sys/kernel/apparmor_restrict_unprivileged_userns', true)} max_user_namespaces=${readSysctl('/proc/sys/user/max_user_namespaces')}`);
}

async function menu(root, mode = 'main') {
  if (mode === 'diagnose') { await showStatus(root); return 0; }
  const settings = mode === 'settings';
  while (true) {
    console.log('\n=== 便携 AI 工具箱（Linux）===');
    console.log('1. 启动 Claude Code（需先设置/解锁 CC Switch）'); console.log('2. 选择工作目录并启动 Claude Code');
    console.log('3. 诊断与运行时状态'); console.log('4. 明确发起连接测试');
    console.log('5. Python / uv 状态与项目环境'); console.log('6. CC Switch：离线打开');
    console.log('7. CC Switch：联网打开'); console.log('8. 锁定并保存 CC Switch'); console.log('9. 检查运行时'); console.log('10. 升级盘内 Linux 运行时');
    console.log('11. 恢复断盘后加密保存在本机的会话'); console.log('0. 退出');
    const choice = await ask('请选择：');
    try {
      if (choice === '0') return 0;
      if (choice === '3' || choice === '9') await showStatus(root);
      else if (choice === '1' || choice === '2') {
        let workDir;
        if (choice === '2') workDir = await getWorkDir(root);
        else {
          try { workDir = validateWorkDirectory(root, process.cwd()); }
          catch { console.log('当前目录属于主目录、U 盘根目录或工具箱运行数据；请选择项目目录。'); workDir = await getWorkDir(root); }
        }
        await startClaude(root, workDir);
      }
      else if (choice === '4') {
        const phrase = await ask('连接测试会实际向所选供应商发送请求。确认请输入 TEST：');
        if (phrase === 'TEST') await testCurrentProvider(root); else console.log('已取消。');
      } else if (choice === '5') await pythonMenu(root);
      else if (choice === '6') await runCcSwitch(root, false);
      else if (choice === '7') await runCcSwitch(root, true);
      else if (choice === '8') {
        if (await lockActiveManager(root)) console.log('本 U 盘 CC Switch 已安全关闭并加密保存。');
        else console.log('当前没有正在运行的本 U 盘 CC Switch 窗口。');
      }
      else if (choice === '10') await upgradeLinux(root);
      else if (choice === '11') await recoverPrivateBundles(root);
      else console.log('无效选项。');
    } catch (e) { console.error(`操作失败：${e.message}`); }
    if (settings && choice === '0') return 0;
  }
}

async function pythonMenu(root) {
  ensurePrivateDir(privateBase());
  const sessionDir = await fsp.mkdtemp(path.join(privateBase(), 'python-'));
  let projectDir = null, environmentPath = null, usesPrivateEnvironment = false;
  try {
    const stagePython = runtimeApi.stagePython || runtimeApi.stageRuntime;
    let staged;
    try { staged = await stagePython(root, sessionDir); }
    catch (e) { console.log(`盘内 Python/uv 尚未就绪：${e.message}`); return; }
    console.log(`盘内 Python/uv 已就绪：${staged.pythonVersion || 'Python 3.12'}；${path.basename(staged.uv)}`);
    const action = await ask('创建项目虚拟环境？输入项目目录，留空返回：'); if (!action) return;
    if (!path.isAbsolute(action)) throw new Error('请输入完整项目目录路径。');
    const dir = path.resolve(action); projectDir = dir; await fsp.mkdir(dir, { recursive: true });
    const paths = pythonEnvironmentLayout(root, dir);
    const privateEnvironment = paths.privateEnvironment;
    usesPrivateEnvironment = privateEnvironment;
    const { cacheRoot, stableRoot, venv } = paths;
    environmentPath = venv;
    assertNoLinks(privateEnvironment ? cacheRoot : path.dirname(stableRoot));
    if (privateEnvironment) ensurePrivateDir(path.dirname(cacheRoot));
    if (!fs.existsSync(stableRoot)) {
      fs.mkdirSync(path.dirname(stableRoot), { recursive: true, mode: 0o700 });
      const stagedPythonRoot = path.join(sessionDir, 'python-stage', 'python');
      fs.cpSync(stagedPythonRoot, stableRoot, { recursive: true, dereference: false, verbatimSymlinks: true, errorOnExist: true });
    }
    const stagedPythonRoot = path.join(sessionDir, 'python-stage', 'python');
    const stablePython = path.join(stableRoot, path.relative(stagedPythonRoot, staged.python));
    assertNoLinks(stablePython);
    if (!fs.existsSync(stablePython) || !fs.statSync(stablePython).isFile()) throw new Error('项目内稳定 Python 副本无效；没有创建虚拟环境。');
    if (fs.existsSync(venv)) throw new Error('项目 .venv 已存在；为保护已有环境，未覆盖。');
    const { spawnSync } = require('node:child_process');
    const result = spawnSync(staged.uv, ['venv', '--no-config', '--no-project', '--python', stablePython, venv], { cwd: dir, stdio: 'inherit', env: { PATH: path.dirname(staged.uv) + path.delimiter + '/usr/bin:/bin', HOME: privateBase(), UV_NO_CONFIG: '1', UV_NO_PROJECT: '1' } });
    if (result.error || result.status !== 0) throw new Error('uv venv failed; the staged project Python copy was retained.');
  } finally { await fsp.rm(sessionDir, { recursive: true, force: true }); }
  const check = require('node:child_process').spawnSync(path.join(environmentPath, 'bin', 'python'), ['--version'], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', HOME: privateBase() } });
  if (check.error || check.status !== 0) throw new Error('Created .venv could not run after temporary staging was removed; inspect and keep the project runtime copy.');
  console.log(`已创建并验证：${environmentPath}${usesPrivateEnvironment ? '（项目所在文件系统禁止执行；环境保存在本机私有托管目录）' : '（项目内 .venv，解释器引用项目内稳定副本）'}。`);
}

function mountedFileSystem(dir, mountInfo = fs.readFileSync('/proc/self/mountinfo', 'utf8')) {
  if (process.platform !== 'linux') return false;
  const unescape = (s) => s.replace(/\\([0-7]{3})/g, (_, n) => String.fromCharCode(parseInt(n, 8)));
  let best = null;
  for (const line of mountInfo.split('\n')) {
    const halves = line.split(' - '), fields = halves[0]?.split(/\s+/), tail = halves[1]?.split(/\s+/); if (!fields || fields.length < 6 || !tail?.length) continue;
    const mount = unescape(fields[4]);
    if ((dir === mount || dir.startsWith(mount.endsWith('/') ? mount : mount + '/')) && (!best || mount.length > best.mount.length)) best = { mount, options: fields[5].split(','), type: tail[0] };
  }
  return best;
}
function mountedNoExec(dir, mountInfo) { return !!mountedFileSystem(dir, mountInfo)?.options.includes('noexec'); }
function mountedNeedsPrivatePython(dir, mountInfo) {
  const info = mountedFileSystem(dir, mountInfo), fsType = info?.type || '';
  return !!info?.options.includes('noexec') || /^(?:vfat|fat|exfat|ntfs|ntfs3|fuseblk|9p|cifs|smb3)$/i.test(fsType);
}
function pythonEnvironmentLayout(root, dir, mountInfo) {
  root = fs.realpathSync(root); dir = fs.realpathSync(dir);
  const info = mountInfo === undefined ? undefined : mountInfo;
  const privateEnvironment = mountedNeedsPrivatePython(dir, info);
  const identity = usbIdentity(root);
  const projectKey = crypto.createHash('sha256').update(`${identity.dev}\0${identity.mountSource || ''}\0${dir}`).digest('hex');
  const cacheRoot = path.join(privateBase(), 'python-projects', projectKey);
  return { privateEnvironment, cacheRoot,
    stableRoot: privateEnvironment ? path.join(cacheRoot, 'python-runtime-3.12') : path.join(dir, '.portable-ai', 'python-runtime-3.12'),
    venv: privateEnvironment ? path.join(cacheRoot, 'venv') : path.join(dir, '.venv') };
}

async function testCurrentProvider(root) {
  const opened = await unlock(root, false);
  try {
    const live = await getLiveProvider(root), snapshot = await store.readSnapshot(opened);
    if (!live && !snapshot.size) throw new Error('还没有可测试的 CC Switch 供应商。');
    await testProvider(live || store.providerFromSnapshot(snapshot));
  } finally { opened.close(); }
}

async function upgradeLinux(root) {
  const confirm = await ask('升级会从官方来源下载并替换盘内 Linux 运行时、CC Switch 与 Claude Code。输入 UPGRADE 继续：');
  if (confirm !== 'UPGRADE') { console.log('已取消。'); return; }
  const script = path.join(root, 'scripts', 'bootstrap-linux.sh');
  if (!fs.existsSync(script)) throw new Error('Linux 升级脚本不存在。');
  const result = require('node:child_process').spawnSync('bash', [script, root], { stdio: 'inherit' });
  if (result.error || result.status !== 0) throw new Error(`Linux runtime upgrade failed (${result.status}).`);
}

async function runCli({ root, mode = 'main' }) {
  if (!fs.existsSync(path.join(root, 'scripts', 'linux-encrypted-store.cjs'))) throw new Error('Linux toolbox modules are incomplete. Run the bootstrap from the USB root and sync the complete source set.');
  await recoverOrphanSessions(root);
  return menu(root, mode);
}

module.exports = { askSecret, usbIdentity, stillMounted, createPrivateSession, acquireWriterLease, releaseWriterLease, saveAndRemove, startClaude, runCcSwitch, gateSandboxUserns, restoreSessionSnapshot, awaitSandboxReady, waitForChild, showStatus, runCli, installExitHandlers, sessionCount: () => sessions.size, captureClaudeHistory, latestClaudeHistory, restoreLatestClaudeHistory, validateHistoryPayload, localizeCcSwitchSettings, restorePortablePathSettings, validateWorkDirectory, startProviderBroker, stopProviderBroker, getLiveProvider, lockActiveManager, recoverPrivateBundles, restorePrivateBundle, writePrivateOwner, recoverOrphanSession, recoverOrphanSessions, testProvider, scrubClaudeSettings, mountedNoExec, mountedNeedsPrivatePython, pythonEnvironmentLayout, watchForUnplug };
