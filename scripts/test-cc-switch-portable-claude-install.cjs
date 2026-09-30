'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const installer = require('./cc-switch-portable-claude-install.cjs');

function tar(entries) {
  const chunks = [];
  for (const e of entries) {
    const name = Buffer.from(e.name, 'utf8');
    assert.ok(name.length <= 100);
    const data = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data || '');
    const h = Buffer.alloc(512);
    name.copy(h, 0);
    putOctal(h, 100, 8, 0o644);
    putOctal(h, 108, 8, 0); putOctal(h, 116, 8, 0);
    putOctal(h, 124, 12, e.size === undefined ? data.length : e.size);
    putOctal(h, 136, 12, 0);
    h.fill(32, 148, 156);
    h[156] = (e.type || '0').charCodeAt(0);
    Buffer.from('ustar\0').copy(h, 257); Buffer.from('00').copy(h, 263);
    Buffer.from('test').copy(h, 265); Buffer.from('test').copy(h, 297);
    const checksum = h.reduce((s, b) => s + b, 0);
    const check = checksum.toString(8).padStart(6, '0') + '\0 ';
    Buffer.from(check, 'ascii').copy(h, 148);
    chunks.push(h);
    if (data.length) {
      chunks.push(data);
      const pad = (512 - data.length % 512) % 512;
      if (pad) chunks.push(Buffer.alloc(pad));
    }
  }
  chunks.push(Buffer.alloc(1024));
  return zlib.gzipSync(Buffer.concat(chunks));
}
function putOctal(b, at, len, n) {
  const s = n.toString(8).padStart(len - 1, '0') + '\0';
  Buffer.from(s, 'ascii').copy(b, at);
}
function code(expected, fn) {
  assert.throws(fn, e => e && e.code === expected);
}
function makePe(version) {
  const b = Buffer.alloc(1024 * 1024);
  const pe = 0x80, opt = pe + 24, section = opt + 240, raw = 0x200;
  b.write('MZ', 0, 'ascii'); b.writeUInt32LE(pe, 0x3c); b.write('PE\0\0', pe, 'ascii');
  b.writeUInt16LE(0x8664, pe + 4); b.writeUInt16LE(1, pe + 6); b.writeUInt16LE(240, pe + 20);
  b.writeUInt16LE(0x20b, opt); b.writeUInt32LE(16, opt + 108);
  b.writeUInt32LE(0x1000, opt + 112 + 16); b.writeUInt32LE(0x200, opt + 112 + 20);
  b.writeUInt32LE(0x500, section + 8); b.writeUInt32LE(0x1000, section + 12);
  b.writeUInt32LE(0x500, section + 16); b.writeUInt32LE(raw, section + 20);
  const dir = raw;
  b.writeUInt16LE(0, dir + 12); b.writeUInt16LE(1, dir + 14);
  b.writeUInt32LE(16, dir + 16); b.writeUInt32LE(0x80000018, dir + 20);
  b.writeUInt16LE(0, dir + 24 + 12); b.writeUInt16LE(1, dir + 24 + 14);
  b.writeUInt32LE(1, dir + 40); b.writeUInt32LE(0x80000030, dir + 44);
  b.writeUInt16LE(0, dir + 48 + 12); b.writeUInt16LE(1, dir + 48 + 14);
  b.writeUInt32LE(0x409, dir + 64); b.writeUInt32LE(0x60, dir + 68);
  b.writeUInt32LE(0x1100, dir + 96); b.writeUInt32LE(128, dir + 100);
  const dataAt = raw + 0x100;
  const key = Buffer.from('VS_VERSION_INFO\0', 'utf16le');
  const valueAt = (6 + key.length + 3) & ~3;
  b.writeUInt16LE(valueAt + 52, dataAt); b.writeUInt16LE(52, dataAt + 2); b.writeUInt16LE(0, dataAt + 4); key.copy(b, dataAt + 6);
  const fixed = dataAt + valueAt;
  b.writeUInt32LE(0xfeef04bd, fixed); b.writeUInt32LE(0x10000, fixed + 4);
  const parts = version.split('.').map(Number);
  const ms = (parts[0] << 16) | parts[1], ls = (parts[2] << 16) | 0;
  b.writeUInt32LE(ms, fixed + 8); b.writeUInt32LE(ls, fixed + 12);
  b.writeUInt32LE(ms, fixed + 16); b.writeUInt32LE(ls, fixed + 20);
  return b;
}

test('accepts only explicit Claude install argument forms', () => {
  for (const args of [
    ['i', '-g', '@anthropic-ai/claude-code@latest'],
    ['i', '--global', '@anthropic-ai/claude-code@latest'],
    ['install', '-g', '@anthropic-ai/claude-code@latest'],
    ['install', '--global', '@anthropic-ai/claude-code@latest'],
  ]) assert.doesNotThrow(() => installer.validateArgs(args));
  for (const args of [
    ['i', '-g', 'other@latest'], ['i', '-g', '@anthropic-ai/claude-code'],
    ['i', '-g', '@anthropic-ai/claude-code@latest', '--registry=https://evil.test'],
    ['i', '-g', '@anthropic-ai/claude-code@latest', '--prefix=C:\\outside'],
    ['install', 'https://evil.test/pkg.tgz'], [],
  ]) code('E_ARGS', () => installer.validateArgs(args));
});

test('rejects tar traversal, links, duplicates, and overlong entry bounds', () => {
  code('E_TAR_PATH', () => installer.parseTarGzip(tar([{ name: 'package/../../outside', data: 'x' }])));
  code('E_TAR_PATH', () => installer.parseTarGzip(tar([{ name: 'package/C:/escape', data: 'x' }])));
  code('E_TAR_TYPE', () => installer.parseTarGzip(tar([{ name: 'package/link', type: '2', data: 'package/x' }])));
  code('E_TAR_DUPLICATE', () => installer.parseTarGzip(tar([{ name: 'package/a', data: 'one' }, { name: 'package/A', data: 'two' }])));
  code('E_TAR_DUPLICATE', () => installer.parseTarGzip(tar([{ name: 'package/Foo/a', data: 'one' }, { name: 'package/foo/b', data: 'two' }])));
  code('E_TAR_SIZE', () => installer.parseTarGzip(tar([{ name: 'package/a', data: 'x', size: 2048 }])));
});

test('parses a bounded legal package archive and rejects invalid integrity', () => {
  const archive = tar([{ name: 'package/', type: '5' }, { name: 'package/package.json', data: '{"name":"example"}' }]);
  const entries = installer.parseTarGzip(archive);
  assert.deepEqual(entries.map(e => e.path), ['package', 'package/package.json']);
  const integrity = `sha512-${crypto.createHash('sha512').update(archive).digest('base64')}`;
  assert.equal(installer.verifyIntegrity(archive, integrity), true);
  code('E_INTEGRITY', () => installer.verifyIntegrity(archive, `sha512-${Buffer.alloc(64).toString('base64')}`));
  code('E_INTEGRITY', () => installer.verifyIntegrity(archive, 'sha1-unsupported'));
});

test('rejects slot prefix escape and accepts the direct owned slot', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'portable-claude-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const rel of ['runtime/node', 'runtime/updates', 'harness/slots/2.1.0/node_modules/@anthropic-ai/claude-code', 'harness/updates']) fs.mkdirSync(path.join(root, rel), { recursive: true });
  fs.writeFileSync(path.join(root, '.aistick-ac-probe'), installer.constants.ROOT_MARKER);
  const scriptDir = path.join(root, 'runtime', 'updates');
  const prefix = path.join(root, 'harness', 'slots', '2.1.0');
  assert.deepEqual(installer.validateLayout(scriptDir, { npm_config_prefix: prefix }).slotId, '2.1.0');
  code('E_PREFIX', () => installer.validateLayout(scriptDir, { npm_config_prefix: path.join(root, 'harness', 'slots-escape', '2.1.0') }));
  code('E_PREFIX', () => installer.validateLayout(scriptDir, { npm_config_prefix: path.join(root, 'harness', 'slots', '..', 'outside') }));
});

test('reads x64 PE version resources and rejects a package version mismatch', () => {
  const pe = installer.parsePeVersion(makePe('2.3.4'));
  assert.equal(pe.fileVersion, '2.3.4.0');
  assert.equal(pe.productVersion, '2.3.4.0');
  assert.doesNotThrow(() => installer.assertVersions(pe, '2.3.4', '2.3.4'));
  code('E_VERSION', () => installer.assertVersions(pe, '2.3.5', '2.3.5'));
  code('E_VERSION', () => installer.assertVersions(pe, '2.3.4', '2.3.5'));
  const malformed = makePe('2.3.4');
  malformed.writeUInt16LE(40, 0x200 + 0x100); // Root declares only the key, while bytes after it look like FIXEDFILEINFO.
  code('E_PE_VERSION', () => installer.parsePeVersion(malformed));
});

function transactionFixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-transaction-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const slot = path.join(root, 'harness', 'slots', '1.0.0');
  const active = path.join(slot, 'node_modules', '@anthropic-ai', 'claude-code');
  const shim = path.join(slot, 'claude.cmd');
  const update = path.join(root, 'harness', 'updates', 'transaction');
  const stage = path.join(update, 'stagedClaudePkg');
  for (const rel of ['runtime/node', 'runtime/updates', 'harness/slots', 'harness/updates']) fs.mkdirSync(path.join(root, rel), { recursive: true });
  fs.writeFileSync(path.join(root, '.aistick-ac-probe'), installer.constants.ROOT_MARKER);
  fs.mkdirSync(active, { recursive: true });
  fs.writeFileSync(path.join(active, 'package.json'), JSON.stringify({ name: installer.constants.PARENT_NAME, version: '1.0.0' }));
  fs.writeFileSync(shim, 'old shim\r\n');
  fs.mkdirSync(stage, { recursive: true });
  const parentArchive = tar([
    { name: 'package/package.json', data: JSON.stringify({ name: installer.constants.PARENT_NAME, version: '2.0.0' }) },
    { name: 'package/bin/claude.exe', data: 'unused small launcher placeholder' },
  ]);
  const platformArchive = tar([
    { name: 'package/package.json', data: JSON.stringify({ name: installer.constants.PLATFORM_NAME, version: '2.0.0' }) },
    { name: 'package/claude.exe', data: makePe('2.0.0') },
  ]);
  installer.extractEntries(installer.parseTarGzip(parentArchive), root, path.relative(root, stage));
  const platform = path.join(stage, 'node_modules', '@anthropic-ai', 'claude-code-win32-x64');
  installer.extractEntries(installer.parseTarGzip(platformArchive), root, path.relative(root, platform));
  return {
    root,
    layout: { ownedRoot: root, prefix: slot, slotId: '1.0.0' },
    activeRel: path.relative(root, active),
    stageRel: path.relative(root, stage),
    updateRel: path.relative(root, update),
    shimRel: path.relative(root, shim),
    active,
    shim,
    stage,
  };
}

test('commits the extracted official tar layout and keeps the fixed slot path on upgrade', t => {
  const f = transactionFixture(t);
  assert.equal(installer.compareStableVersions('2.0.0', '1.9.99'), 1);
  assert.equal(installer.compareStableVersions('1.9.99', '2.0.0'), -1);
  assert.doesNotThrow(() => installer.commitCandidate(f.layout, f.activeRel, f.stageRel, f.updateRel, f.shimRel, '2.0.0'));
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.active, 'package.json'), 'utf8')).version, '2.0.0');
  assert.equal(fs.readFileSync(f.shim, 'utf8'), installer.constants.SHIM);
  assert.equal(fs.existsSync(path.join(f.active, 'node_modules', '@anthropic-ai', 'claude-code-win32-x64', 'claude.exe')), true);
});

test('rolls back package and shim when the final shim rename fails', t => {
  const f = transactionFixture(t);
  const finalShim = path.join(f.root, f.shimRel);
  let injected = false;
  const io = {
    writeFileSync: fs.writeFileSync.bind(fs),
    renameSync(from, to) {
      if (!injected && to === finalShim && path.basename(from) === 'claude.cmd.new') {
        injected = true;
        const e = new Error('fixture rename failure'); e.code = 'EIO'; throw e;
      }
      return fs.renameSync(from, to);
    },
  };
  assert.throws(() => installer.commitCandidate(f.layout, f.activeRel, f.stageRel, f.updateRel, f.shimRel, '2.0.0', io), /fixture rename failure/);
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.active, 'package.json'), 'utf8')).version, '1.0.0');
  assert.equal(fs.readFileSync(f.shim, 'utf8'), 'old shim\r\n');
  assert.equal(fs.existsSync(path.join(f.stage, 'package.json')), true, 'candidate is restored to its private staging path');
});

test('retries a transient Windows EPERM while publishing the candidate package', t => {
  const f = transactionFixture(t);
  const activePath = path.join(f.root, f.activeRel);
  const stagePath = path.join(f.root, f.stageRel);
  let failedOnce = false, renameAttempts = 0, waited = 0;
  const io = {
    writeFileSync: fs.writeFileSync.bind(fs),
    waitSync(ms) { waited += ms; },
    renameSync(from, to) {
      if (from === stagePath && to === activePath) {
        renameAttempts++;
        if (!failedOnce) { failedOnce = true; const e = new Error('sharing violation'); e.code = 'EPERM'; e.syscall = 'rename'; throw e; }
      }
      return fs.renameSync(from, to);
    },
  };
  assert.doesNotThrow(() => installer.commitCandidate(f.layout, f.activeRel, f.stageRel, f.updateRel, f.shimRel, '2.0.0', io));
  assert.equal(renameAttempts, 2);
  assert.equal(waited, 40);
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.active, 'package.json'), 'utf8')).version, '2.0.0');
});

test('reports the failed publish phase and restores the active package after bounded EPERM retries', t => {
  const f = transactionFixture(t);
  const activePath = path.join(f.root, f.activeRel);
  const stagePath = path.join(f.root, f.stageRel);
  let renameAttempts = 0, waited = 0;
  const io = {
    writeFileSync: fs.writeFileSync.bind(fs),
    waitSync(ms) { waited += ms; },
    renameSync(from, to) {
      if (from === stagePath && to === activePath) {
        renameAttempts++;
        const e = new Error('access temporarily denied'); e.code = 'EPERM'; e.syscall = 'rename'; throw e;
      }
      return fs.renameSync(from, to);
    },
  };
  assert.throws(
    () => installer.commitCandidate(f.layout, f.activeRel, f.stageRel, f.updateRel, f.shimRel, '2.0.0', io),
    e => e.code === 'EPERM' && e.commitPhase === 'publish-candidate-package' && e.syscall === 'rename' && e.sourcePath === stagePath && e.destinationPath === activePath,
  );
  assert.equal(renameAttempts, 4, 'one initial rename plus three bounded retries');
  assert.equal(waited, 410, 'retry delay is capped at 410ms');
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.active, 'package.json'), 'utf8')).version, '1.0.0');
  assert.equal(fs.existsSync(path.join(f.stage, 'package.json')), true);
});

test('treats rename that moves then throws as failure and preserves the old-package backup', t => {
  const f = transactionFixture(t);
  const activePath = path.join(f.root, f.activeRel);
  const stagePath = path.join(f.root, f.stageRel);
  const backupPath = path.join(f.root, f.updateRel, 'old-claude-code');
  let movedThenThrew = false;
  const io = {
    writeFileSync: fs.writeFileSync.bind(fs),
    waitSync() {},
    renameSync(from, to) {
      if (from === stagePath && to === activePath && !movedThenThrew) {
        movedThenThrew = true;
        fs.renameSync(from, to);
        const e = new Error('injected post-rename EPERM'); e.code = 'EPERM'; e.syscall = 'rename'; throw e;
      }
      if (from === backupPath && to === activePath && fs.existsSync(activePath)) {
        const e = new Error('destination already exists'); e.code = 'EEXIST'; e.syscall = 'rename'; throw e;
      }
      return fs.renameSync(from, to);
    },
  };
  assert.throws(
    () => installer.commitCandidate(f.layout, f.activeRel, f.stageRel, f.updateRel, f.shimRel, '2.0.0', io),
    e => e.code === 'EPERM' && e.commitPhase === 'publish-candidate-package' && e.retryErrors.some(message => message.startsWith('ENOENT:')) && e.rollbackPhase === 'rollback-restore-active-package' && /destination already exists/.test(e.rollbackMessage),
  );
  assert.equal(JSON.parse(fs.readFileSync(path.join(backupPath, 'package.json'), 'utf8')).version, '1.0.0', 'old package remains recoverable in the private transaction backup');
  assert.equal(JSON.parse(fs.readFileSync(path.join(activePath, 'package.json'), 'utf8')).version, '2.0.0', 'the uncertain publish is reported as failure rather than inferred as success');
  assert.equal(fs.readFileSync(path.join(f.shim), 'utf8'), 'old shim\r\n');
});

class MockRequest extends EventEmitter {
  constructor() { super(); this.destroyed = false; }
  destroy() { this.destroyed = true; this.emit('close'); return this; }
}
class MockResponse extends EventEmitter {
  constructor(statusCode = 200, headers = {}) { super(); this.statusCode = statusCode; this.headers = headers; this.complete = false; this.destroyed = false; }
  destroy() { this.destroyed = true; this.emit('close'); return this; }
}
function mockedGet(handler, requests = []) {
  return (url, options, callback) => {
    const req = new MockRequest(); requests.push({ req, url, options });
    queueMicrotask(() => handler({ req, url, options, callback }));
    return req;
  };
}
function deliverResponse(callback, statusCode, body = Buffer.alloc(0), headers = {}) {
  const response = new MockResponse(statusCode, headers);
  callback(response);
  queueMicrotask(() => {
    if (body.length) response.emit('data', body);
    response.complete = true;
    response.emit('end');
    response.emit('close');
  });
  return response;
}

test('retries a GET reset then returns a complete bounded response', async () => {
  let calls = 0; const waits = [];
  const body = Buffer.from('{"name":"Claude"}');
  const transport = mockedGet(({ req, callback }) => {
    calls++;
    if (calls === 1) { const error = new Error('socket reset'); error.code = 'ECONNRESET'; req.emit('error', error); }
    else deliverResponse(callback, 200, body, { 'content-length': String(body.length) });
  });
  const result = await installer.requestBuffer('https://registry.npmjs.org/test', 1000, {
    transport, wait: async ms => { waits.push(ms); },
  });
  assert.equal(result.toString(), body.toString());
  assert.equal(calls, 2);
  assert.deepEqual(waits, [100]);
});

test('exhausted transport retries preserve the actual network code and resource path', async () => {
  let calls = 0; const waits = [];
  const transport = mockedGet(({ req }) => {
    calls++; const error = new Error('private transport detail'); error.code = 'ECONNRESET'; req.emit('error', error);
  });
  await assert.rejects(
    installer.requestBuffer('https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/latest', 1000, { transport, wait: async ms => waits.push(ms) }),
    error => error.code === 'ECONNRESET' && error.resource === '/@anthropic-ai%2Fclaude-code/latest' && !error.message.includes('private transport detail'),
  );
  assert.equal(calls, 3);
  assert.deepEqual(waits, [100, 300]);
});

test('metadata JSON errors are distinct from transport errors and never expose response bodies', async () => {
  let calls = 0;
  const body = Buffer.from('{bad-secret-payload');
  const transport = mockedGet(({ callback }) => { calls++; deliverResponse(callback, 200, body, { 'content-length': String(body.length) }); });
  await assert.rejects(
    installer.fetchJson('https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/latest', { transport, maxRetries: 0 }),
    error => error.code === 'E_METADATA_JSON' && error.resource === '/@anthropic-ai%2Fclaude-code/latest' && !error.message.includes('bad-secret-payload'),
  );
  assert.equal(calls, 1);
});

test('aborted and truncated responses settle once and cancel the request', async () => {
  const requests = []; let response;
  const transport = mockedGet(({ callback }) => {
    response = new MockResponse(200, {}); callback(response);
    queueMicrotask(() => { response.emit('aborted'); response.emit('close'); });
  }, requests);
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/test', 100, { transport, maxRetries: 0 }), e => e.code === 'E_NET_TRUNCATED');
  assert.equal(requests[0].req.destroyed, true);
  assert.equal(response.destroyed, true);

  const incomplete = Buffer.from('abc');
  const transport2 = mockedGet(({ callback }) => deliverResponse(callback, 200, incomplete, { 'content-length': '10' }));
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/test', 100, { transport: transport2, maxRetries: 0 }), e => e.code === 'E_NET_TRUNCATED');
});

test('request deadline aborts a hanging GET and retry backoff cannot exceed its total budget', async () => {
  const requests = [];
  const hanging = mockedGet(() => {}, requests);
  const started = Date.now();
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/hang', 100, { transport: hanging, maxRetries: 0, deadlineMs: 30 }), e => e.code === 'E_TIMEOUT');
  assert.ok(Date.now() - started < 500);
  assert.equal(requests[0].req.destroyed, true);

  let calls = 0; const startRetry = Date.now();
  const reset = mockedGet(({ req }) => { calls++; const e = new Error('reset'); e.code = 'ECONNRESET'; req.emit('error', e); });
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/budget', 100, { transport: reset, deadlineMs: 140 }), e => e.code === 'E_TIMEOUT' && e.retryCode === 'ECONNRESET');
  assert.equal(calls, 2);
  assert.ok(Date.now() - startRetry < 500);
});

test('rejects redirect without a location and rejects redirect host escape', async () => {
  const missing = mockedGet(({ callback }) => deliverResponse(callback, 302, Buffer.alloc(0), {}));
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/start', 100, { transport: missing, maxRetries: 0 }), e => e.code === 'E_REDIRECT');
  const escape = mockedGet(({ callback }) => deliverResponse(callback, 302, Buffer.alloc(0), { location: 'https://example.invalid/steal' }));
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/start', 100, { transport: escape, maxRetries: 0 }), e => e.code === 'E_REDIRECT');
});

test('fetches only the exact-version mirror tarball, permits its pinned CDN redirect, and verifies official SRI', async () => {
  const archive = Buffer.from('official archive bytes');
  const meta = {
    name: '@anthropic-ai/claude-code', version: '2.1.285',
    dist: {
      tarball: 'https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/-/claude-code-2.1.285.tgz',
      integrity: `sha512-${crypto.createHash('sha512').update(archive).digest('base64')}`,
    },
  };
  const seen = [];
  const transport = mockedGet(({ url, callback }) => {
    seen.push(`${url.hostname}${url.pathname}`);
    if (url.hostname === installer.constants.MIRROR) {
      const response = new MockResponse(302, { location: `https://${installer.constants.MIRROR_CDN}/packages/%40anthropic-ai/claude-code/2.1.285/claude-code-2.1.285.tgz` });
      callback(response); response.emit('close');
    } else deliverResponse(callback, 200, archive, { 'content-length': String(archive.length) });
  });
  const result = await installer.fetchPackageTarball(meta, meta.name, meta.version, { transport, wait: async () => {} });
  assert.deepEqual(result, archive);
  assert.equal(seen.length, 2);
  assert.match(seen[0], /^registry\.npmmirror\.com\/@anthropic-ai\/claude-code\/-\/claude-code-2\.1\.285\.tgz$/);
  assert.match(seen[1], /^cdn\.npmmirror\.com\/packages\//);
});

test('falls back to the official exact tarball on mirror transport or SRI failure', async () => {
  const archive = Buffer.from('trusted official archive');
  const wrong = Buffer.from('tampered mirror bytes');
  const meta = {
    name: '@anthropic-ai/claude-code-win32-x64', version: '2.1.285',
    dist: {
      tarball: 'https://registry.npmjs.org/@anthropic-ai%2Fclaude-code-win32-x64/-/claude-code-win32-x64-2.1.285.tgz',
      integrity: `sha512-${crypto.createHash('sha512').update(archive).digest('base64')}`,
    },
  };
  let mirrorCalls = 0, officialCalls = 0;
  const transport = mockedGet(({ req, url, callback }) => {
    if (url.hostname === installer.constants.MIRROR) {
      mirrorCalls++;
      deliverResponse(callback, 200, wrong, { 'content-length': String(wrong.length) });
    } else {
      officialCalls++;
      deliverResponse(callback, 200, archive, { 'content-length': String(archive.length) });
    }
  });
  assert.deepEqual(await installer.fetchPackageTarball(meta, meta.name, meta.version, { transport, wait: async () => {} }), archive);
  assert.equal(mirrorCalls, 1);
  assert.equal(officialCalls, 1);
  await assert.rejects(
    installer.fetchPackageTarball({ ...meta, dist: { ...meta.dist, tarball: 'https://registry.npmjs.org/@anthropic-ai%2Fother/-/other-2.1.285.tgz' } }, meta.name, meta.version, { transport, wait: async () => {} }),
    e => e.code === 'E_URL',
  );
});

test('tarball no-data timeout reports only bounded numeric transfer diagnostics', async () => {
  const transport = mockedGet(({ callback }) => {
    const response = new MockResponse(200, { 'content-length': '12345' }); callback(response);
  });
  await assert.rejects(
    installer.requestBuffer('https://registry.npmjs.org/archive.tgz', 20000, {
      transport, maxRetries: 0, deadlineMs: 100, inactivityTimeoutMs: 20, source: 'official',
    }),
    e => e.code === 'E_IDLE_TIMEOUT' && e.downloadSource === 'official' && e.bytesReceived === 0 && e.contentLength === 12345 && Number.isSafeInteger(e.elapsedMs),
  );
});

test('retries transient HTTP GET status but rejects oversized responses without reading their body', async () => {
  let calls = 0;
  const body = Buffer.from('ok');
  const transient = mockedGet(({ callback }) => {
    calls++;
    if (calls === 1) deliverResponse(callback, 503);
    else deliverResponse(callback, 200, body, { 'content-length': String(body.length) });
  });
  const value = await installer.requestBuffer('https://registry.npmjs.org/status', 100, { transport: transient, wait: async () => {} });
  assert.equal(value.toString(), 'ok');
  assert.equal(calls, 2);

  const requests = [];
  let sentBody = false;
  const oversized = mockedGet(({ callback }) => {
    const response = new MockResponse(200, { 'content-length': '101' });
    callback(response);
    queueMicrotask(() => { if (!response.destroyed) { sentBody = true; response.emit('data', Buffer.alloc(101)); } });
  }, requests);
  await assert.rejects(installer.requestBuffer('https://registry.npmjs.org/large', 100, { transport: oversized, maxRetries: 0 }), e => e.code === 'E_NET_LIMIT');
  assert.equal(requests[0].req.destroyed, true);
  assert.equal(sentBody, false, 'oversized Content-Length is rejected before body delivery');
});

