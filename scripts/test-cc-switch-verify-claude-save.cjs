'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const installer = require('./cc-switch-portable-claude-install.cjs');
const verifier = require('./cc-switch-verify-claude-save.cjs');

function tar(entries) {
  const chunks = [];
  for (const e of entries) {
    const data = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data || '');
    const h = Buffer.alloc(512); Buffer.from(e.name, 'utf8').copy(h, 0);
    octal(h, 100, 8, 0o644); octal(h, 108, 8, 0); octal(h, 116, 8, 0);
    octal(h, 124, 12, data.length); octal(h, 136, 12, 0); h.fill(32, 148, 156);
    h[156] = (e.type || '0').charCodeAt(0); Buffer.from('ustar\0').copy(h, 257); Buffer.from('00').copy(h, 263);
    const checksum = h.reduce((s, b) => s + b, 0);
    Buffer.from(checksum.toString(8).padStart(6, '0') + '\0 ', 'ascii').copy(h, 148);
    chunks.push(h);
    if (data.length) { chunks.push(data); const pad = (512 - data.length % 512) % 512; if (pad) chunks.push(Buffer.alloc(pad)); }
  }
  chunks.push(Buffer.alloc(1024)); return zlib.gzipSync(Buffer.concat(chunks));
}
function octal(b, at, len, n) { Buffer.from(n.toString(8).padStart(len - 1, '0') + '\0', 'ascii').copy(b, at); }
function makePe(version) {
  const b = Buffer.alloc(1024 * 1024);
  b[800000] = 0x5a;
  const pe = 0x80, opt = pe + 24, section = opt + 240, raw = 0x200;
  b.write('MZ', 0, 'ascii'); b.writeUInt32LE(pe, 0x3c); b.write('PE\0\0', pe, 'ascii');
  b.writeUInt16LE(0x8664, pe + 4); b.writeUInt16LE(1, pe + 6); b.writeUInt16LE(240, pe + 20);
  b.writeUInt16LE(0x20b, opt); b.writeUInt32LE(16, opt + 108); b.writeUInt32LE(0x1000, opt + 112 + 16); b.writeUInt32LE(0x200, opt + 112 + 20);
  b.writeUInt32LE(0x500, section + 8); b.writeUInt32LE(0x1000, section + 12); b.writeUInt32LE(0x500, section + 16); b.writeUInt32LE(raw, section + 20);
  const d = raw;
  b.writeUInt16LE(1, d + 14); b.writeUInt32LE(16, d + 16); b.writeUInt32LE(0x80000018, d + 20);
  b.writeUInt16LE(1, d + 24 + 14); b.writeUInt32LE(1, d + 40); b.writeUInt32LE(0x80000030, d + 44);
  b.writeUInt16LE(1, d + 48 + 14); b.writeUInt32LE(0x409, d + 64); b.writeUInt32LE(0x60, d + 68);
  b.writeUInt32LE(0x1100, d + 96); b.writeUInt32LE(128, d + 100);
  const at = raw + 0x100, key = Buffer.from('VS_VERSION_INFO\0', 'utf16le'), valueAt = (6 + key.length + 3) & ~3;
  b.writeUInt16LE(valueAt + 52, at); b.writeUInt16LE(52, at + 2); key.copy(b, at + 6);
  const fixed = at + valueAt, v = version.split('.').map(Number), ms = (v[0] << 16) | v[1], ls = v[2] << 16;
  b.writeUInt32LE(0xfeef04bd, fixed); b.writeUInt32LE(0x10000, fixed + 4);
  b.writeUInt32LE(ms, fixed + 8); b.writeUInt32LE(ls, fixed + 12); b.writeUInt32LE(ms, fixed + 16); b.writeUInt32LE(ls, fixed + 20);
  return b;
}
function metadata(name, version, archive, optionalDependencies) {
  return { name, version, optionalDependencies, dist: {
    tarball: `https://registry.npmjs.org/${encodeURIComponent(name)}/-/${name.split('/')[1]}-${version}.tgz`,
    integrity: `sha512-${crypto.createHash('sha512').update(archive).digest('base64')}`,
    shasum: crypto.createHash('sha1').update(archive).digest('hex'),
  } };
}
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-save-verify-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const candidate = path.join(root, 'candidate'), baseline = path.join(root, 'baseline');
  fs.mkdirSync(candidate); fs.mkdirSync(baseline);
  const version = '2.5.6';
  const exe = makePe(version);
  const parentArchive = tar([
    { name: 'package/', type: '5' },
    { name: 'package/package.json', data: JSON.stringify({ name: '@anthropic-ai/claude-code', version }) },
    { name: 'package/bin/', type: '5' },
    { name: 'package/bin/claude.exe', data: 'small launcher stub' },
    { name: 'package/install.cjs', data: 'untrusted lifecycle payload, compared only as bytes' },
  ]);
  const platformArchive = tar([
    { name: 'package/package.json', data: JSON.stringify({ name: '@anthropic-ai/claude-code-win32-x64', version }) },
    { name: 'package/claude.exe', data: exe },
  ]);
  const packageRoot = path.join(candidate, 'node_modules', '@anthropic-ai', 'claude-code');
  fs.mkdirSync(packageRoot, { recursive: true });
  installer.extractEntries(installer.parseTarGzip(parentArchive), root, path.relative(root, packageRoot));
  const platformRoot = path.join(packageRoot, 'node_modules', '@anthropic-ai', 'claude-code-win32-x64');
  installer.extractEntries(installer.parseTarGzip(platformArchive), root, path.relative(root, platformRoot));
  fs.writeFileSync(path.join(candidate, 'claude.cmd'), installer.constants.SHIM);
  fs.writeFileSync(path.join(baseline, 'claude.cmd'), installer.constants.SHIM);
  fs.writeFileSync(path.join(candidate, 'claude'), '@echo off\r\n');
  fs.writeFileSync(path.join(baseline, 'claude'), '@echo off\r\n');
  const parentMeta = metadata('@anthropic-ai/claude-code', version, parentArchive, { '@anthropic-ai/claude-code-win32-x64': version });
  const platformMeta = metadata('@anthropic-ai/claude-code-win32-x64', version, platformArchive);
  return { root, candidate, baseline, packageRoot, platformRoot, version, parentArchive, platformArchive, parentMeta, platformMeta };
}
function verify(f) {
  return verifier.verifyCandidateWithArchives(f.candidate, f.baseline, f.parentMeta, f.platformMeta, f.parentArchive, f.platformArchive);
}

test('accepts an exact official parent and nested platform archive plus trusted wrappers', t => {
  const f = fixture(t);
  assert.deepEqual(verify(f), { version: f.version });
});

test('save verification reuses official metadata plus mirror-first SRI-checked tarball transport', async t => {
  const f = fixture(t);
  const requests = [];
  const { EventEmitter } = require('node:events');
  const transport = (url, options, callback) => {
    requests.push(url.hostname);
    const req = new EventEmitter(); req.destroyed = false;
    req.destroy = () => { req.destroyed = true; req.emit('close'); };
    queueMicrotask(() => {
      let status = 200, headers = {}, body;
      if (url.hostname === installer.constants.REGISTRY) {
        const meta = url.pathname.includes('claude-code-win32-x64') ? f.platformMeta : f.parentMeta;
        body = Buffer.from(JSON.stringify(meta));
      } else if (url.hostname === installer.constants.MIRROR) {
        status = 302;
        headers.location = `https://${installer.constants.MIRROR_CDN}/packages${url.pathname}`;
      } else if (url.hostname === installer.constants.MIRROR_CDN) {
        body = url.pathname.includes('claude-code-win32-x64') ? f.platformArchive : f.parentArchive;
      } else {
        status = 302;
        headers.location = `https://${installer.constants.MIRROR_CDN}${url.pathname}`;
      }
      if (!headers.location) headers['content-length'] = String(body.length);
      const res = new EventEmitter(); Object.assign(res, { statusCode: status, headers, complete: false, destroyed: false });
      res.destroy = () => { res.destroyed = true; res.emit('close'); };
      callback(res);
      queueMicrotask(() => {
        if (res.destroyed) return;
        if (body && body.length) res.emit('data', body);
        res.complete = true; res.emit('end'); res.emit('close');
      });
    });
    return req;
  };
  const result = await verifier.verifyCandidate(f.candidate, f.baseline, { transport, wait: async () => {} });
  assert.deepEqual(result, { version: f.version });
  assert.equal(requests.slice(0, 2).every(host => host === installer.constants.REGISTRY), true, 'metadata uses the official registry only');
  assert.ok(requests.includes(installer.constants.MIRROR));
  assert.ok(requests.includes(installer.constants.MIRROR_CDN));
});

test('rejects a modified Claude executable even when its PE version remains valid', t => {
  const f = fixture(t);
  const exePath = path.join(f.platformRoot, 'claude.exe');
  const modified = fs.readFileSync(exePath);
  modified[800000] ^= 0x01;
  fs.writeFileSync(exePath, modified);
  assert.throws(() => verify(f), e => e.code === 'E_TREE_CONTENT');
  assert.equal(installer.parsePeVersion(fs.readFileSync(exePath)).fileVersion, `${f.version}.0`);
});

test('rejects an extra package file and an added npm shim', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.packageRoot, 'surprise.js'), 'extra');
  assert.throws(() => verify(f), e => e.code === 'E_TREE_EXTRA');
  fs.unlinkSync(path.join(f.packageRoot, 'surprise.js'));
  fs.writeFileSync(path.join(f.candidate, 'npm.cmd'), 'npm');
  assert.throws(() => verify(f), e => e.code === 'E_TOP_LEVEL');
});

test('rejects a changed top-level shim and modified legacy wrapper', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.candidate, 'claude.cmd'), 'malicious wrapper');
  assert.throws(() => verify(f), e => e.code === 'E_SHIM');
  fs.writeFileSync(path.join(f.candidate, 'claude.cmd'), installer.constants.SHIM);
  fs.writeFileSync(path.join(f.candidate, 'claude'), 'changed wrapper');
  assert.throws(() => verify(f), e => e.code === 'E_LEGACY');
});

test('accepts only the two fixed absolute-path arguments', () => {
  assert.deepEqual(verifier.parseArgs(['--candidate', 'E:\\stage', '--baseline', 'E:\\trusted']), { candidate: 'E:\\stage', baseline: 'E:\\trusted' });
  assert.throws(() => verifier.parseArgs(['--candidate', 'E:\\stage', '--baseline', 'E:\\trusted', '--registry', 'https://evil']), e => e.code === 'E_ARGS');
  assert.throws(() => verifier.parseArgs(['--candidate', 'relative', '--baseline', 'E:\\trusted']), e => e.code === 'E_ARGS');
});
