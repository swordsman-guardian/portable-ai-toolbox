'use strict';

// A deliberately small, dependency-free installer for the managed portable
// Claude slot. This file never invokes npm or package lifecycle scripts.
const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const ROOT_MARKER = 'synthetic appcontainer fixture v1';
const PARENT_NAME = '@anthropic-ai/claude-code';
const PLATFORM_NAME = '@anthropic-ai/claude-code-win32-x64';
const REGISTRY = 'registry.npmjs.org';
const MAX_META = 4 * 1024 * 1024;
const MAX_TARBALL = 256 * 1024 * 1024;
const MAX_UNPACKED = 512 * 1024 * 1024;
const MAX_ENTRIES = 50000;
const MAX_TOTAL_TARBALL = 384 * 1024 * 1024;
const MAX_TOTAL_UNPACKED = 640 * 1024 * 1024;
const MAX_TOTAL_ENTRIES = 60000;
const DEADLINE_MS = 90000;
const TARBALL_BUDGET_MS = 300000;
const TARBALL_IDLE_MS = 30000;
const TARBALL_MIRROR_MS = 210000;
const MIRROR = 'registry.npmmirror.com';
const MIRROR_CDN = 'cdn.npmmirror.com';
const MAX_GET_RETRIES = 2;
const GET_RETRY_DELAYS_MS = [100, 300];
const RENAME_RETRY_DELAYS_MS = [40, 120, 250];
const SHIM = '@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\node_modules\\@anthropic-ai\\claude-code-win32-x64\\claude.exe"   %*\r\n';

class InstallError extends Error {
  constructor(code, message) { super(message); this.name = 'InstallError'; this.code = code; }
}
function fail(code, message) { throw new InstallError(code, message); }

function validateArgs(args) {
  const allowed = [
    ['i', '-g', `${PARENT_NAME}@latest`],
    ['i', '--global', `${PARENT_NAME}@latest`],
    ['install', '-g', `${PARENT_NAME}@latest`],
    ['install', '--global', `${PARENT_NAME}@latest`],
  ];
  if (!Array.isArray(args) || !allowed.some(a => a.length === args.length && a.every((v, i) => v === args[i]))) {
    fail('E_ARGS', 'unsupported Claude install arguments');
  }
}

function isSafeSegment(segment) {
  if (!segment || segment === '.' || segment === '..' || /[\\/:\0]/.test(segment)) return false;
  if (/[. ]$/.test(segment) || /[<>:"|?*]/.test(segment)) return false;
  const stem = segment.split('.')[0].toUpperCase();
  if (/^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$/.test(stem)) return false;
  return true;
}

function safeTarPath(raw) {
  if (typeof raw !== 'string' || !raw || raw.startsWith('/') || raw.startsWith('\\') || raw.includes('\\') || raw.includes('\0')) {
    fail('E_TAR_PATH', 'unsafe tar path');
  }
  let value = raw;
  if (value.endsWith('/')) value = value.slice(0, -1);
  const parts = value.split('/');
  if (parts[0] !== 'package' || parts.some(p => !isSafeSegment(p))) {
    fail('E_TAR_PATH', 'tar entry escapes package root or has an unsafe Windows path');
  }
  return parts.join('/');
}

function parseOctal(field, label) {
  if (!field.length || (field[0] & 0x80) !== 0) fail('E_TAR_HEADER', `unsupported ${label} encoding`);
  const s = field.toString('ascii').replace(/\0.*$/, '').trim();
  if (!s) return 0;
  if (!/^[0-7]+$/.test(s)) fail('E_TAR_HEADER', `invalid ${label}`);
  const n = Number.parseInt(s, 8);
  if (!Number.isSafeInteger(n)) fail('E_TAR_SIZE', `${label} exceeds safe integer range`);
  return n;
}

function parseTarGzip(gzip, { maxCompressed = MAX_TARBALL, maxUnpacked = MAX_UNPACKED, maxEntries = MAX_ENTRIES } = {}) {
  if (!Buffer.isBuffer(gzip) || gzip.length > maxCompressed) fail('E_TAR_LIMIT', 'compressed archive exceeds limit');
  let tar;
  try { tar = zlib.gunzipSync(gzip, { maxOutputLength: maxUnpacked }); }
  catch (e) { fail('E_TAR_GZIP', `invalid or oversized gzip archive: ${e.message}`); }
  if (tar.length > maxUnpacked || tar.length < 1024 || tar.length % 512 !== 0) fail('E_TAR_SIZE', 'invalid tar length');
  const entries = [];
  const seen = new Map();
  let offset = 0, unpacked = 0, zeroBlocks = 0;
  while (offset + 512 <= tar.length) {
    const h = tar.subarray(offset, offset + 512);
    if (h.every(b => b === 0)) { zeroBlocks++; offset += 512; if (zeroBlocks === 2) break; continue; }
    if (zeroBlocks) fail('E_TAR_HEADER', 'nonzero data after tar end marker');
    let sum = 0;
    for (let i = 0; i < 512; i++) sum += (i >= 148 && i < 156) ? 32 : h[i];
    const stored = parseOctal(h.subarray(148, 156), 'checksum');
    if (sum !== stored) fail('E_TAR_CHECKSUM', 'tar header checksum mismatch');
    const magic = h.subarray(257, 263).toString('ascii');
    if (magic !== 'ustar\0' && magic !== 'ustar ') fail('E_TAR_HEADER', 'only USTAR entries are accepted');
    const name = readTarString(h.subarray(0, 100));
    const prefix = readTarString(h.subarray(345, 500));
    const full = prefix ? `${prefix}/${name}` : name;
    const type = h[156] === 0 ? '0' : String.fromCharCode(h[156]);
    if (type !== '0' && type !== '5') fail('E_TAR_TYPE', 'links, PAX, sparse, and special tar entries are rejected');
    const safe = safeTarPath(full);
    const size = parseOctal(h.subarray(124, 136), 'entry size');
    if (type === '5' && size !== 0) fail('E_TAR_SIZE', 'directory entry has data');
    const bodyAt = offset + 512;
    if (size > maxUnpacked || bodyAt + size > tar.length) fail('E_TAR_SIZE', 'tar entry exceeds archive bounds');
    const parts = safe.split('/');
    for (let i = 1; i <= parts.length; i++) {
      const prefix = parts.slice(0, i).join('/');
      const folded = prefix.toLocaleLowerCase('en-US');
      const isFinal = i === parts.length;
      const prev = seen.get(folded);
      if (prev && prev.path !== prefix) fail('E_TAR_DUPLICATE', 'implicit or explicit tar directories collide by case');
      if (isFinal) {
        if (prev && prev.explicit) fail('E_TAR_DUPLICATE', 'duplicate tar entry');
        if (prev && type === '0') fail('E_TAR_COLLISION', 'a file entry conflicts with an implicit directory');
        seen.set(folded, { path: prefix, explicit: true, type: type === '5' ? 'directory' : 'file' });
      } else {
        if (prev && prev.explicit && prev.type === 'file') fail('E_TAR_COLLISION', 'file entry is used as a directory');
        if (!prev) seen.set(folded, { path: prefix, explicit: false, type: 'directory' });
      }
    }
    unpacked += size;
    if (unpacked > maxUnpacked || entries.length >= maxEntries) fail('E_TAR_LIMIT', 'archive entry or expanded size limit exceeded');
    entries.push({ path: safe, type: type === '5' ? 'directory' : 'file', data: tar.subarray(bodyAt, bodyAt + size) });
    offset = bodyAt + Math.ceil(size / 512) * 512;
  }
  if (zeroBlocks < 2) fail('E_TAR_END', 'tar end marker is missing');
  if (tar.subarray(offset).some(b => b !== 0)) fail('E_TAR_END', 'nonzero bytes after tar end marker');
  // A file cannot also be an ancestor of another entry.
  const kinds = new Map(entries.map(e => [e.path.toLocaleLowerCase('en-US'), e.type]));
  for (const e of entries) {
    const parts = e.path.split('/');
    for (let i = 1; i < parts.length; i++) {
      const ancestor = parts.slice(0, i).join('/').toLocaleLowerCase('en-US');
      if (kinds.get(ancestor) === 'file') fail('E_TAR_COLLISION', 'file entry is used as a directory');
    }
  }
  return entries;
}
function readTarString(b) {
  const nul = b.indexOf(0);
  const value = b.subarray(0, nul < 0 ? b.length : nul).toString('utf8');
  if (value.includes('\uFFFD')) fail('E_TAR_HEADER', 'invalid UTF-8 path');
  return value;
}

function verifyIntegrity(data, integrity, shasum) {
  if (!Buffer.isBuffer(data)) data = Buffer.from(data);
  if (typeof integrity !== 'string') fail('E_INTEGRITY', 'SHA512 dist.integrity is required');
  const tokens = integrity.trim().split(/\s+/);
  const accepted = tokens.filter(t => t.startsWith('sha512-'));
  if (!accepted.length) fail('E_INTEGRITY', 'SHA512 dist.integrity is required');
  const actual = crypto.createHash('sha512').update(data).digest();
  let matched = false;
  for (const token of accepted) {
    const expected = Buffer.from(token.slice(7), 'base64');
    if (expected.length === actual.length && crypto.timingSafeEqual(expected, actual)) matched = true;
  }
  if (!matched) fail('E_INTEGRITY', 'archive SHA512 integrity mismatch');
  if (shasum !== undefined) {
    if (typeof shasum !== 'string' || !/^[a-f0-9]{40}$/i.test(shasum) || crypto.createHash('sha1').update(data).digest('hex').toLowerCase() !== shasum.toLowerCase()) {
      fail('E_INTEGRITY', 'archive SHA1 shasum mismatch');
    }
  }
  return true;
}

function assertPlainTree(root, relative, { create = false, directory = true } = {}) {
  const relParts = relative ? relative.split(/[\\/]/) : [];
  if (relParts.some(p => !isSafeSegment(p))) fail('E_PATH', 'unsafe managed path');
  let current = root;
  const checkOne = (p, shouldDir) => {
    let st;
    try { st = fs.lstatSync(p); }
    catch (e) {
      if (e.code !== 'ENOENT' || !create) throw e;
      if (shouldDir) fs.mkdirSync(p); else return null;
      st = fs.lstatSync(p);
    }
    if (st.isSymbolicLink() || (typeof st.isReparsePoint === 'function' && st.isReparsePoint()) || (typeof st.attributes === 'number' && (st.attributes & 0x400) !== 0)) fail('E_REPARSE', 'managed paths cannot contain reparse points');
    if (shouldDir ? !st.isDirectory() : !st.isFile()) fail('E_PATH_TYPE', 'managed path has an unexpected type');
    return st;
  };
  checkOne(root, true);
  for (let i = 0; i < relParts.length; i++) {
    current = path.join(current, relParts[i]);
    const isFinal = i === relParts.length - 1;
    const wantDir = isFinal ? directory : true;
    checkOne(current, wantDir);
  }
  return current;
}

function validateLayout(scriptDir, env = process.env) {
  const ownedRoot = path.dirname(path.dirname(scriptDir));
  if (path.resolve(scriptDir).toLowerCase() !== path.resolve(ownedRoot, 'runtime', 'updates').toLowerCase()) fail('E_LAYOUT', 'installer must run from ownedRoot/runtime/updates');
  assertPlainTree(ownedRoot, '', { directory: true });
  const marker = path.join(ownedRoot, '.aistick-ac-probe');
  assertPlainTree(ownedRoot, '.aistick-ac-probe', { directory: false });
  const markerText = fs.readFileSync(marker, 'utf8').replace(/\r?\n$/, '');
  if (markerText !== ROOT_MARKER) fail('E_ROOT_MARKER', 'owned root marker is invalid');
  for (const rel of ['runtime', 'runtime/node', 'harness', 'harness/slots', 'runtime/updates']) {
    assertPlainTree(ownedRoot, rel, { directory: true });
  }
  assertPlainTree(ownedRoot, 'harness/updates', { directory: true, create: true });
  const prefix = env.npm_config_prefix;
  if (typeof prefix !== 'string' || !path.isAbsolute(prefix)) fail('E_PREFIX', 'npm_config_prefix must identify an owned slot');
  const slotsRoot = path.join(ownedRoot, 'harness', 'slots');
  const resolvedPrefix = path.resolve(prefix);
  if (path.dirname(resolvedPrefix).toLowerCase() !== slotsRoot.toLowerCase()) fail('E_PREFIX', 'npm_config_prefix must be a direct child of harness/slots');
  const slotId = path.basename(resolvedPrefix);
  if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(slotId)) fail('E_PREFIX', 'slot id is invalid');
  assertPlainTree(ownedRoot, path.relative(ownedRoot, resolvedPrefix), { directory: true });
  const pkgRel = path.relative(ownedRoot, path.join(resolvedPrefix, 'node_modules', '@anthropic-ai', 'claude-code'));
  assertPlainTree(ownedRoot, pkgRel, { directory: true });
  return { ownedRoot, prefix: resolvedPrefix, slotId };
}

function parsePeVersion(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 1024 * 1024) fail('E_PE_SIZE', 'Claude executable must be at least 1 MiB');
  if (buffer.toString('ascii', 0, 2) !== 'MZ') fail('E_PE', 'executable is not a PE image');
  const peAt = buffer.readUInt32LE(0x3c);
  if (peAt < 0x40 || peAt + 24 > buffer.length || buffer.toString('ascii', peAt, peAt + 4) !== 'PE\0\0') fail('E_PE', 'invalid PE header');
  if (buffer.readUInt16LE(peAt + 4) !== 0x8664) fail('E_PE_ARCH', 'Claude executable is not x64');
  const sectionCount = buffer.readUInt16LE(peAt + 6);
  const optSize = buffer.readUInt16LE(peAt + 20);
  const optAt = peAt + 24;
  if (sectionCount < 1 || sectionCount > 96 || optAt + optSize + sectionCount * 40 > buffer.length) fail('E_PE', 'invalid PE section table');
  if (buffer.readUInt16LE(optAt) !== 0x20b || optSize < 112 + 3 * 8) fail('E_PE', 'PE32+ optional header is required');
  const dirCount = buffer.readUInt32LE(optAt + 108);
  if (dirCount < 3) fail('E_PE_VERSION', 'PE version resource directory is missing');
  const resRva = buffer.readUInt32LE(optAt + 112 + 16);
  const resSize = buffer.readUInt32LE(optAt + 112 + 20);
  if (!resRva || resSize < 16 || resSize > 16 * 1024 * 1024) fail('E_PE_VERSION', 'PE version resource directory is missing or oversized');
  const sections = [];
  for (let i = 0; i < sectionCount; i++) {
    const s = optAt + optSize + i * 40;
    sections.push({ va: buffer.readUInt32LE(s + 12), vs: buffer.readUInt32LE(s + 8), raw: buffer.readUInt32LE(s + 20), rs: buffer.readUInt32LE(s + 16) });
  }
  function rvaOffset(rva, len = 1) {
    for (const s of sections) {
      const span = Math.max(s.vs, s.rs);
      if (rva >= s.va && rva - s.va <= span && len <= span - (rva - s.va)) {
        const off = s.raw + (rva - s.va);
        if (off >= 0 && off + len <= buffer.length) return off;
      }
    }
    fail('E_PE_VERSION', 'PE resource RVA is outside file data');
  }
  const rootOff = rvaOffset(resRva, resSize);
  function entries(dirRel) {
    if (dirRel < 0 || dirRel + 16 > resSize) fail('E_PE_VERSION', 'invalid PE resource directory');
    const off = rootOff + dirRel;
    const named = buffer.readUInt16LE(off + 12), ids = buffer.readUInt16LE(off + 14), n = named + ids;
    if (n > 4096 || dirRel + 16 + n * 8 > resSize) fail('E_PE_VERSION', 'invalid PE resource entry count');
    const arr = [];
    for (let i = 0; i < n; i++) arr.push({ name: buffer.readUInt32LE(off + 16 + i * 8), target: buffer.readUInt32LE(off + 20 + i * 8) });
    return arr;
  }
  const root = entries(0).find(e => !(e.name & 0x80000000) && e.name === 16 && (e.target & 0x80000000));
  if (!root) fail('E_PE_VERSION', 'RT_VERSION resource is missing');
  const nameEntry = entries(root.target & 0x7fffffff).find(e => e.target & 0x80000000);
  if (!nameEntry) fail('E_PE_VERSION', 'version resource data is missing');
  const langEntry = entries(nameEntry.target & 0x7fffffff)[0];
  if (!langEntry || (langEntry.target & 0x80000000)) fail('E_PE_VERSION', 'version resource data entry is invalid');
  const dataEntryRel = langEntry.target & 0x7fffffff;
  if (dataEntryRel + 16 > resSize) fail('E_PE_VERSION', 'version data entry is out of bounds');
  const dataEntryOff = rootOff + dataEntryRel;
  const dataRva = buffer.readUInt32LE(dataEntryOff), dataSize = buffer.readUInt32LE(dataEntryOff + 4);
  if (dataSize < 40 || dataSize > 1024 * 1024) fail('E_PE_VERSION', 'version resource size is invalid');
  const dataOff = rvaOffset(dataRva, dataSize);
  const end = dataOff + dataSize;
  const key = 'VS_VERSION_INFO\0';
  const keyBytes = Buffer.from(key, 'utf16le');
  const wLength = buffer.readUInt16LE(dataOff), wValueLength = buffer.readUInt16LE(dataOff + 2), wType = buffer.readUInt16LE(dataOff + 4);
  if (wLength < 40 || wLength > dataSize || wType !== 0 || wValueLength < 52 || !buffer.subarray(dataOff + 6, dataOff + 6 + keyBytes.length).equals(keyBytes)) fail('E_PE_VERSION', 'malformed VS_VERSION_INFO');
  const valueAt = dataOff + ((6 + keyBytes.length + 3) & ~3);
  const versionRootEnd = dataOff + wLength;
  if (valueAt + 52 > versionRootEnd || valueAt + wValueLength > versionRootEnd || versionRootEnd > end || buffer.readUInt32LE(valueAt) !== 0xfeef04bd) fail('E_PE_VERSION', 'VS_FIXEDFILEINFO exceeds declared VS_VERSION_INFO bounds');
  const fileMS = buffer.readUInt32LE(valueAt + 8), fileLS = buffer.readUInt32LE(valueAt + 12);
  const productMS = buffer.readUInt32LE(valueAt + 16), productLS = buffer.readUInt32LE(valueAt + 20);
  const ver = (ms, ls) => `${ms >>> 16}.${ms & 0xffff}.${ls >>> 16}.${ls & 0xffff}`;
  return { fileVersion: ver(fileMS, fileLS), productVersion: ver(productMS, productLS) };
}

function assertVersions(pe, parentVersion, platformVersion) {
  const expected = new Set([parentVersion, platformVersion]);
  if (expected.size !== 1) fail('E_VERSION', 'parent and platform package versions do not match');
  const matches = v => v.split('.').length === 4 && v.endsWith('.0') && v.split('.').slice(0, 3).join('.') === parentVersion;
  if (!matches(pe.fileVersion) || !matches(pe.productVersion)) fail('E_VERSION', `PE version resource does not match package ${parentVersion}`);
}

function extractEntries(entries, ownedRoot, stagingRelative) {
  const stage = assertPlainTree(ownedRoot, stagingRelative, { directory: true, create: true });
  for (const entry of entries) {
    const relParts = entry.path.split('/').slice(1);
    if (relParts.length === 0) continue;
    let currentRel = stagingRelative;
    for (let i = 0; i < relParts.length; i++) {
      const final = i === relParts.length - 1;
      currentRel = path.join(currentRel, relParts[i]);
      const wantDir = final ? entry.type === 'directory' : true;
      const target = assertPlainTree(ownedRoot, currentRel, { create: true, directory: wantDir });
      if (final && entry.type === 'file') {
        // file must not already exist; a validated tar may contain explicit parents only once.
        if (fs.existsSync(target)) fail('E_TAR_COLLISION', 'tar destination already exists');
        fs.writeFileSync(target, entry.data, { flag: 'wx' });
      }
    }
  }
  return stage;
}

function safeNetworkCode(error) {
  return error && typeof error.code === 'string' && /^[A-Z0-9_]{1,48}$/.test(error.code) ? error.code : 'E_NETWORK';
}
function attachResource(error, url) {
  if (!error.resource) error.resource = url.pathname;
  return error;
}
function transportError(error, url) {
  const code = safeNetworkCode(error);
  return attachResource(new InstallError(code, code === 'E_NETWORK' ? 'registry transport failed' : `registry transport failed (${code})`), url);
}
function requestOnce(url, maxBytes, deadlineAt, transport, options = {}) {
  return new Promise((resolve, reject) => {
    const remaining = deadlineAt - Date.now();
    if (remaining <= 0) { reject(attachResource(new InstallError('E_TIMEOUT', 'registry request deadline exceeded'), url)); return; }
    let req = null, res = null, settled = false, responseEnded = false, byteCount = 0;
    let declaredLength = null;
    const chunks = [];
    let timer, idleTimer;
    const startedAt = Date.now();
    const inactivityMs = Number.isFinite(options.inactivityTimeoutMs) ? options.inactivityTimeoutMs : 0;
    const noop = () => {};
    const cancel = () => {
      if (res && !res.destroyed) { res.on('error', noop); try { res.destroy(); } catch {} }
      if (req && !req.destroyed) { req.on('error', noop); try { req.destroy(); } catch {} }
    };
    const finish = (error, result, abort = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(idleTimer);
      if (error) {
        attachResource(error, url);
        error.downloadSource = options.source || 'official';
        error.bytesReceived = byteCount;
        error.contentLength = declaredLength;
        error.elapsedMs = Date.now() - startedAt;
        if (abort) cancel();
        reject(error);
      } else resolve(result);
    };
    const resetIdleTimer = () => {
      if (!inactivityMs || settled) return;
      clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        const error = attachResource(new InstallError('E_IDLE_TIMEOUT', 'tarball request had no data before the inactivity limit'), url);
        finish(error, undefined, true);
      }, Math.min(inactivityMs, Math.max(1, deadlineAt - Date.now())));
    };
    const truncated = () => attachResource(new InstallError('E_NET_TRUNCATED', 'registry response ended before its declared length'), url);
    const onResponse = response => {
      res = response;
      if (settled) { cancel(); return; }
      resetIdleTimer();
      response.on('error', error => finish(transportError(error, url), undefined, true));
      response.on('aborted', () => finish(attachResource(new InstallError('E_NET_TRUNCATED', 'registry response was aborted'), url), undefined, true));
      response.on('close', () => {
        if (!settled && response.statusCode === 200 && (!response.complete || !responseEnded)) finish(truncated(), undefined, true);
      });

      if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
        const location = response.headers && response.headers.location;
        response.on('error', noop);
        finish(null, { kind: 'redirect', location });
        try { response.destroy(); } catch {}
        return;
      }
      if (response.statusCode !== 200) {
        const statusCode = response.statusCode;
        const error = attachResource(new InstallError('E_HTTP', `registry returned HTTP ${statusCode}`), url);
        error.statusCode = statusCode;
        finish(error, undefined, true);
        return;
      }
      const rawLength = response.headers && response.headers['content-length'];
      if (rawLength !== undefined) {
        if (Array.isArray(rawLength) || !/^\d+$/.test(String(rawLength))) {
          finish(attachResource(new InstallError('E_CONTENT_LENGTH', 'registry response length header is invalid'), url), undefined, true);
          return;
        }
        declaredLength = Number(rawLength);
        if (!Number.isSafeInteger(declaredLength) || declaredLength > maxBytes) {
          finish(attachResource(new InstallError('E_NET_LIMIT', 'registry response exceeds size limit'), url), undefined, true);
          return;
        }
      }
      response.on('data', chunk => {
        if (settled) return;
        resetIdleTimer();
        const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        byteCount += data.length;
        if (byteCount > maxBytes) {
          finish(attachResource(new InstallError('E_NET_LIMIT', 'registry response exceeds size limit'), url), undefined, true);
          return;
        }
        chunks.push(data);
      });
      response.on('end', () => {
        responseEnded = true;
        if (settled) return;
        if (response.complete === false || declaredLength !== null && byteCount !== declaredLength) {
          finish(truncated(), undefined, true);
          return;
        }
        finish(null, { buffer: Buffer.concat(chunks, byteCount) });
      });
    };

    timer = setTimeout(() => finish(attachResource(new InstallError('E_TIMEOUT', 'registry request deadline exceeded'), url), undefined, true), remaining);
    resetIdleTimer();
    try {
      req = transport(url, {
        headers: { 'accept-encoding': 'identity', 'user-agent': 'cc-switch-portable-installer/1' },
        timeout: remaining,
      }, onResponse);
      req.on('error', error => finish(transportError(error, url), undefined, true));
      req.on('timeout', () => finish(attachResource(new InstallError('E_TIMEOUT', 'registry request deadline exceeded'), url), undefined, true));
      req.on('close', () => {
        if (!settled && !res) finish(attachResource(new InstallError('E_NET_CLOSED', 'registry connection closed before a response'), url), undefined, true);
      });
    } catch (error) {
      finish(transportError(error, url), undefined, true);
    }
  });
}
function retryableGetError(error) {
  if (error && error.code === 'E_HTTP') return [408, 425, 429, 500, 502, 503, 504].includes(error.statusCode);
  return new Set(['ECONNRESET', 'ECONNREFUSED', 'ECONNABORTED', 'EPIPE', 'ETIMEDOUT', 'EHOSTUNREACH', 'ENETUNREACH', 'ENOTFOUND', 'EAI_AGAIN', 'ERR_STREAM_PREMATURE_CLOSE', 'E_NET_TRUNCATED', 'E_NET_CLOSED', 'E_IDLE_TIMEOUT']).has(error && error.code);
}
function defaultWait(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
async function waitWithinDeadline(ms, deadlineAt, wait) {
  const remaining = deadlineAt - Date.now();
  if (remaining <= 0) fail('E_TIMEOUT', 'registry request deadline exceeded');
  if (ms >= remaining) {
    await wait(remaining);
    fail('E_TIMEOUT', 'registry request deadline exceeded');
  }
  await wait(ms);
  if (Date.now() >= deadlineAt) fail('E_TIMEOUT', 'registry request deadline exceeded');
}
async function requestBuffer(urlString, maxBytes, options = {}) {
  let current;
  try { current = new URL(urlString); } catch { fail('E_URL', 'invalid registry URL'); }
  const defaultDeadline = Number.isFinite(options.maxDeadlineMs) ? options.maxDeadlineMs : DEADLINE_MS;
  const deadlineMs = Math.min(defaultDeadline, Number.isFinite(options.deadlineMs) ? Math.max(1, options.deadlineMs) : defaultDeadline);
  const deadlineAt = Number.isFinite(options.deadlineAt) ? Math.min(options.deadlineAt, Date.now() + deadlineMs) : Date.now() + deadlineMs;
  const transport = options.transport || https.get;
  const wait = options.wait || defaultWait;
  const maxRetries = Math.min(MAX_GET_RETRIES, Number.isInteger(options.maxRetries) ? Math.max(0, options.maxRetries) : MAX_GET_RETRIES);
  const allowedHosts = new Set(options.allowedHosts || [REGISTRY]);
  const fixedHosts = new Set([REGISTRY, MIRROR, MIRROR_CDN]);
  if ([...allowedHosts].some(host => !fixedHosts.has(host))) fail('E_URL', 'request allowlist contains an unapproved HTTPS host');
  let redirects = 0;
  for (;;) {
    if (current.protocol !== 'https:' || !allowedHosts.has(current.hostname) || current.username || current.password || current.port) fail('E_URL', 'URL is outside the fixed HTTPS allowlist');
    let attempt = 0;
    let redirectTarget = null;
    for (;;) {
      try {
        const result = await requestOnce(current, maxBytes, deadlineAt, transport, options);
        if (result.kind === 'redirect') {
          if (typeof result.location !== 'string' || !result.location || result.location.length > 4096 || redirects >= 3) fail('E_REDIRECT', 'registry redirect is missing, malformed, or exceeds the hop limit');
          let next;
          try { next = new URL(result.location, current); } catch { fail('E_REDIRECT', 'registry redirect URL is invalid'); }
          if (next.protocol !== 'https:' || !allowedHosts.has(next.hostname) || next.username || next.password || next.port) fail('E_REDIRECT', 'redirect left approved HTTPS hosts');
          redirectTarget = next;
          break;
        }
        return result.buffer;
      } catch (error) {
        attachResource(error, current);
        if (!retryableGetError(error) || attempt >= maxRetries) throw error;
        const delayMs = GET_RETRY_DELAYS_MS[attempt];
        try { await waitWithinDeadline(delayMs, deadlineAt, wait); }
        catch (deadlineError) { attachResource(deadlineError, current); deadlineError.retryCode = error.code; throw deadlineError; }
        attempt++;
      }
    }
    current = redirectTarget;
    redirects++;
  }
}
async function fetchJson(url, options = {}) {
  const response = await requestBuffer(url, MAX_META, options);
  try { return JSON.parse(response.toString('utf8')); }
  catch {
    let resource = '';
    try { resource = new URL(url).pathname; } catch {}
    const error = new InstallError('E_METADATA_JSON', 'registry metadata is invalid JSON');
    if (resource) error.resource = resource;
    throw error;
  }
}
function validatePackageMetadata(meta, name, version) {
  if (!meta || meta.name !== name || meta.version !== version || !meta.dist || typeof meta.dist.tarball !== 'string' || typeof meta.dist.integrity !== 'string') fail('E_METADATA', `official metadata for ${name} is incomplete`);
  const u = new URL(meta.dist.tarball);
  if (u.protocol !== 'https:' || u.hostname !== REGISTRY || u.username || u.password || u.port) fail('E_URL', 'package tarball URL is outside the approved registry');
  return meta;
}
function expectedTarballPath(name, version) {
  const base = name.split('/').pop();
  return `/${name}/-/${base}-${version}.tgz`;
}
function exactOfficialTarballUrl(meta, name, version) {
  let u;
  try { u = new URL(meta.dist.tarball); } catch { fail('E_URL', 'official package tarball URL is invalid'); }
  if (u.protocol !== 'https:' || u.hostname !== REGISTRY || u.username || u.password || u.port || u.search || u.hash) fail('E_URL', 'official package tarball URL is outside the approved registry');
  let decoded;
  try { decoded = decodeURIComponent(u.pathname); } catch { fail('E_URL', 'official tarball path is invalid'); }
  if (decoded !== expectedTarballPath(name, version)) fail('E_URL', 'official tarball path does not match the exact package and version');
  return u.href;
}
function mirrorTarballUrl(name, version) {
  const base = name.split('/').pop();
  return `https://${MIRROR}/${name}/-/${base}-${version}.tgz`;
}
async function fetchPackageTarball(meta, name, version, options = {}) {
  if (![PARENT_NAME, PLATFORM_NAME].includes(name) || !validateSemver(version)) fail('E_PACKAGE', 'only the exact stable Claude package names and versions are allowed');
  validatePackageMetadata(meta, name, version);
  const officialUrl = exactOfficialTarballUrl(meta, name, version);
  const deadlineAt = Number.isFinite(options.deadlineAt) ? options.deadlineAt : Date.now() + TARBALL_BUDGET_MS;
  const maxBytes = Math.min(MAX_TARBALL, Number.isFinite(options.maxBytes) ? options.maxBytes : MAX_TARBALL);
  const common = {
    deadlineAt, deadlineMs: TARBALL_BUDGET_MS, maxDeadlineMs: TARBALL_BUDGET_MS,
    inactivityTimeoutMs: TARBALL_IDLE_MS, maxRetries: MAX_GET_RETRIES,
    transport: options.transport, wait: options.wait,
  };
  let mirrorError;
  const mirrorStartedAt = Date.now();
  const mirrorDeadlineAt = Math.min(deadlineAt, Date.now() + TARBALL_MIRROR_MS);
  if (!options.officialOnly) {
    try {
      const bytes = await requestBuffer(mirrorTarballUrl(name, version), maxBytes, {
        ...common, deadlineAt: mirrorDeadlineAt, allowedHosts: [MIRROR, MIRROR_CDN], source: 'npmmirror',
      });
      try { verifyIntegrity(bytes, meta.dist.integrity, meta.dist.shasum); }
      catch (error) {
        error.downloadSource = 'npmmirror'; error.resource = new URL(mirrorTarballUrl(name, version)).pathname;
        error.bytesReceived = bytes.length; error.contentLength = bytes.length; error.elapsedMs = Date.now() - mirrorStartedAt; throw error;
      }
      return bytes;
    } catch (error) { mirrorError = error; }
  }
  try {
    const bytes = await requestBuffer(officialUrl, maxBytes, {
      ...common, allowedHosts: [REGISTRY], source: 'official',
    });
    verifyIntegrity(bytes, meta.dist.integrity, meta.dist.shasum);
    return bytes;
  } catch (officialError) {
    if (mirrorError) {
      officialError.mirrorCode = mirrorError.code || 'E_NETWORK';
      officialError.mirrorBytesReceived = Number.isSafeInteger(mirrorError.bytesReceived) ? mirrorError.bytesReceived : 0;
      officialError.mirrorContentLength = Number.isSafeInteger(mirrorError.contentLength) ? mirrorError.contentLength : null;
      officialError.mirrorElapsedMs = Number.isSafeInteger(mirrorError.elapsedMs) ? mirrorError.elapsedMs : 0;
      officialError.mirrorResource = mirrorError.resource || new URL(mirrorTarballUrl(name, version)).pathname;
    }
    throw officialError;
  }
}
function validateSemver(v) { return typeof v === 'string' && /^\d+\.\d+\.\d+$/.test(v); }
function compareStableVersions(a, b) {
  if (!validateSemver(a) || !validateSemver(b)) fail('E_VERSION', 'stable package version is invalid');
  const aa = a.split('.').map(Number), bb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (aa[i] !== bb[i]) return aa[i] < bb[i] ? -1 : 1;
  return 0;
}

async function downloadAndExtract(meta, name, version, ownedRoot, stageRel, budget) {
  const compressedLimit = Math.min(MAX_TARBALL, budget.compressed);
  const data = await fetchPackageTarball(meta, name, version, { maxBytes: compressedLimit, deadlineAt: budget.deadlineAt, officialOnly: !!budget.officialOnly, transport: budget.transport, wait: budget.wait });
  budget.compressed -= data.length;
  verifyIntegrity(data, meta.dist.integrity, meta.dist.shasum);
  const entries = parseTarGzip(data, {
    maxCompressed: compressedLimit,
    maxUnpacked: Math.min(MAX_UNPACKED, budget.unpacked),
    maxEntries: Math.min(MAX_ENTRIES, budget.entries),
  });
  const expanded = entries.reduce((sum, entry) => sum + (entry.type === 'file' ? entry.data.length : 0), 0);
  budget.unpacked -= expanded;
  budget.entries -= entries.length;
  assertPlainTree(ownedRoot, stageRel, { directory: true, create: true });
  extractEntries(entries, ownedRoot, stageRel);
  return entries.length;
}

function readManifest(file) {
  let obj;
  try { obj = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { fail('E_SLOT', 'active package manifest is invalid'); }
  if (!obj || obj.name !== PARENT_NAME || !validateSemver(obj.version)) fail('E_SLOT', 'active Claude slot is not a stable package');
  return obj;
}

function removeTreeOwned(ownedRoot, relative) {
  const target = assertPlainTree(ownedRoot, relative, { directory: true });
  const walk = rel => {
    const p = path.join(ownedRoot, rel);
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink() || (typeof st.attributes === 'number' && (st.attributes & 0x400) !== 0)) fail('E_REPARSE', 'refusing to clean reparse point');
    if (st.isDirectory()) {
      for (const child of fs.readdirSync(p)) walk(path.join(rel, child));
      fs.rmdirSync(p);
    } else if (st.isFile()) fs.unlinkSync(p);
    else fail('E_PATH_TYPE', 'refusing to clean special filesystem entry');
  };
  walk(relative);
}

function verifyPackageTree(ownedRoot, packageRel, expectedVersion) {
  // Recurse from the package root with lstat at every child; no reparse point
  // or special filesystem entry is allowed anywhere in a staged/active tree.
  const rootPath = assertPlainTree(ownedRoot, packageRel, { directory: true });
  const visit = (rel, full) => {
    const st = fs.lstatSync(full);
    if (st.isSymbolicLink() || (typeof st.attributes === 'number' && (st.attributes & 0x400) !== 0)) fail('E_REPARSE', 'package tree contains a reparse point');
    if (st.isDirectory()) {
      for (const child of fs.readdirSync(full)) {
        if (!isSafeSegment(child)) fail('E_PATH', 'package tree contains an unsafe name');
        visit(path.join(rel, child), path.join(full, child));
      }
    } else if (!st.isFile()) fail('E_PATH_TYPE', 'package tree contains a special filesystem entry');
  };
  visit(packageRel, rootPath);
  const manifest = readManifest(path.join(rootPath, 'package.json'));
  if (manifest.version !== expectedVersion) fail('E_VERSION', 'candidate Claude package version changed');
  const platformRoot = path.join(rootPath, 'node_modules', '@anthropic-ai', 'claude-code-win32-x64');
  const platformRel = path.relative(ownedRoot, platformRoot);
  assertPlainTree(ownedRoot, path.join(platformRel, 'package.json'), { directory: false });
  const platform = JSON.parse(fs.readFileSync(path.join(platformRoot, 'package.json'), 'utf8'));
  if (platform.name !== PLATFORM_NAME || platform.version !== expectedVersion) fail('E_VERSION', 'candidate platform package identity changed');
  const exePath = path.join(platformRoot, 'claude.exe');
  assertPlainTree(ownedRoot, path.relative(ownedRoot, exePath), { directory: false });
  assertVersions(parsePeVersion(fs.readFileSync(exePath)), expectedVersion, platform.version);
  return manifest;
}

function commitCandidate(layout, activeRel, candidateRel, updateRel, shimRel, expectedVersion, io = fs) {
  const { ownedRoot } = layout;
  verifyPackageTree(ownedRoot, candidateRel, expectedVersion);
  assertPlainTree(ownedRoot, activeRel, { directory: true });
  assertPlainTree(ownedRoot, shimRel, { directory: false });
  const backupRel = path.join(updateRel, 'old-claude-code');
  const oldShimRel = path.join(updateRel, 'old-claude.cmd');
  const newShimRel = path.join(updateRel, 'claude.cmd.new');
  let oldMoved = false, newMoved = false, shimBacked = false, shimInstalled = false, phase = 'verify-candidate';
  const wait = ms => {
    if (typeof io.waitSync === 'function') return io.waitSync(ms);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  };
  const move = (from, to, movePhase) => {
    const source = path.join(ownedRoot, from), destination = path.join(ownedRoot, to);
    const retryable = new Set(['EPERM', 'EBUSY', 'EACCES']);
    let firstError = null;
    const retryErrors = [];
    for (let attempt = 0; ; attempt++) {
      try { io.renameSync(source, destination); return; }
      catch (error) {
        error.commitPhase = movePhase;
        error.sourcePath = source;
        error.destinationPath = destination;
        if (!firstError) firstError = error;
        retryErrors.push(`${error.code || 'ERROR'}: ${error.message || 'rename failed'}`);
        if (!retryable.has(error.code) || attempt >= RENAME_RETRY_DELAYS_MS.length) {
          firstError.retryErrors = retryErrors;
          throw firstError;
        }
        wait(RENAME_RETRY_DELAYS_MS[attempt]);
      }
    }
  };
  try {
    phase = 'backup-active-package';
    move(activeRel, backupRel, phase); oldMoved = true;
    phase = 'publish-candidate-package';
    move(candidateRel, activeRel, phase); newMoved = true;
    const newShim = assertPlainTree(ownedRoot, newShimRel, { directory: false, create: true });
    io.writeFileSync(newShim, SHIM, { flag: 'wx' });
    phase = 'backup-claude-shim';
    move(shimRel, oldShimRel, phase); shimBacked = true;
    phase = 'publish-claude-shim';
    move(newShimRel, shimRel, phase); shimInstalled = true;
    phase = 'verify-published-package';
    verifyPackageTree(ownedRoot, activeRel, expectedVersion);
    assertPlainTree(ownedRoot, shimRel, { directory: false });
    if (fs.readFileSync(path.join(ownedRoot, shimRel), 'utf8') !== SHIM) fail('E_SHIM', 'installed Claude shim differs from expected template');
  } catch (error) {
    const originalPhase = error.commitPhase || phase;
    try {
      if (shimInstalled) fs.unlinkSync(path.join(ownedRoot, shimRel));
      if (shimBacked && fs.existsSync(path.join(ownedRoot, oldShimRel))) move(oldShimRel, shimRel, 'rollback-restore-claude-shim');
      if (newMoved && fs.existsSync(path.join(ownedRoot, activeRel))) move(activeRel, candidateRel, 'rollback-unpublish-candidate');
      if (oldMoved && fs.existsSync(path.join(ownedRoot, backupRel))) move(backupRel, activeRel, 'rollback-restore-active-package');
    } catch (rollbackError) {
      error.rollbackPhase = rollbackError.commitPhase || 'rollback';
      error.rollbackMessage = String(rollbackError && rollbackError.message || rollbackError);
    }
    error.commitPhase = originalPhase;
    throw error;
  }
  // The old package remains intact until the new tree, PE resource, and shim
  // have all passed their post-rename checks. Cleanup is best effort.
  try { removeTreeOwned(ownedRoot, backupRel); } catch {}
  try { fs.unlinkSync(path.join(ownedRoot, oldShimRel)); } catch {}
  return { version: expectedVersion };
}

async function install(args, env = process.env, scriptDir = __dirname) {
  validateArgs(args);
  const layout = validateLayout(scriptDir, env);
  const { ownedRoot, prefix, slotId } = layout;
  assertPlainTree(ownedRoot, path.relative(ownedRoot, __filename), { directory: false });
  const lockRel = path.join('harness', 'updates', `slot-${slotId}.lock`);
  const lockPath = assertPlainTree(ownedRoot, lockRel, { directory: false, create: true });
  let lockFd;
  try { lockFd = fs.openSync(lockPath, 'wx', 0o600); }
  catch (e) { if (e.code === 'EEXIST') fail('E_BUSY', 'an update lock exists; close and reopen the USB CC session before retrying'); throw e; }
  try { return await installLocked(args, env, scriptDir, layout); }
  finally {
    try { fs.closeSync(lockFd); } catch {}
    try { fs.unlinkSync(lockPath); } catch {}
  }
}

async function installLocked(args, env, scriptDir, layout) {
  const { ownedRoot, prefix, slotId } = layout;
  validateArgs(args);
  const activeRel = path.relative(ownedRoot, path.join(prefix, 'node_modules', '@anthropic-ai', 'claude-code'));
  const oldManifest = readManifest(path.join(ownedRoot, activeRel, 'package.json'));
  if (!validateSemver(oldManifest.version)) fail('E_SLOT', 'active package version is invalid');
  const updateId = crypto.randomUUID().replace(/-/g, '');
  const updateRel = path.join('harness', 'updates', updateId);
  assertPlainTree(ownedRoot, updateRel, { directory: true, create: true });
  const parentStageRel = path.join(updateRel, 'stagedClaudePkg');
  const platformStageRel = path.join(parentStageRel, 'node_modules', '@anthropic-ai', 'claude-code-win32-x64');
  const shimRel = path.relative(ownedRoot, path.join(prefix, 'claude.cmd'));
  const candidateRel = parentStageRel;
  const stagedPkgPath = path.join(ownedRoot, candidateRel);
  const platformPkgPath = path.join(ownedRoot, platformStageRel);
  const archiveBudget = { compressed: MAX_TOTAL_TARBALL, unpacked: MAX_TOTAL_UNPACKED, entries: MAX_TOTAL_ENTRIES };
  try {
    const latest = await fetchJson(`https://${REGISTRY}/@anthropic-ai%2Fclaude-code/latest`);
    if (latest.name !== PARENT_NAME || !validateSemver(latest.version)) fail('E_METADATA', 'latest metadata is not a stable official Claude release');
    if (compareStableVersions(latest.version, oldManifest.version) < 0) fail('E_VERSION_DOWNGRADE', 'registry latest is older than the active Claude package');
    const parentMeta = validatePackageMetadata(latest, PARENT_NAME, latest.version);
    const platformVersion = latest.optionalDependencies && latest.optionalDependencies[PLATFORM_NAME];
    if (platformVersion !== latest.version) fail('E_METADATA', 'latest metadata does not pin the matching Windows x64 package version');
    const platformRaw = await fetchJson(`https://${REGISTRY}/@anthropic-ai%2Fclaude-code-win32-x64/${encodeURIComponent(platformVersion)}`);
    const platformMeta = validatePackageMetadata(platformRaw, PLATFORM_NAME, platformVersion);
    archiveBudget.deadlineAt = Date.now() + TARBALL_BUDGET_MS;
    await downloadAndExtract(parentMeta, PARENT_NAME, latest.version, ownedRoot, parentStageRel, archiveBudget);
    const stagedManifest = readManifest(path.join(stagedPkgPath, 'package.json'));
    if (stagedManifest.version !== latest.version) fail('E_METADATA', 'parent archive version does not match registry metadata');
    await downloadAndExtract(platformMeta, PLATFORM_NAME, platformVersion, ownedRoot, platformStageRel, archiveBudget);
    const stagedPlatformManifestPath = path.join(platformPkgPath, 'package.json');
    const stagedPlatform = JSON.parse(fs.readFileSync(stagedPlatformManifestPath, 'utf8'));
    if (stagedPlatform.name !== PLATFORM_NAME || stagedPlatform.version !== platformVersion) fail('E_METADATA', 'platform archive package identity does not match metadata');
    const exePath = path.join(platformPkgPath, 'claude.exe');
    const exeRel = path.relative(ownedRoot, exePath);
    assertPlainTree(ownedRoot, exeRel, { directory: false });
    const exe = fs.readFileSync(exePath);
    const pe = parsePeVersion(exe);
    assertVersions(pe, stagedManifest.version, stagedPlatform.version);

    commitCandidate(layout, activeRel, candidateRel, updateRel, shimRel, stagedManifest.version);
    try { fs.rmdirSync(path.join(ownedRoot, updateRel)); } catch {}
    return { version: stagedManifest.version };
  } catch (error) {
    if (!error.rollbackMessage) try { if (fs.existsSync(stagedPkgPath)) removeTreeOwned(ownedRoot, parentStageRel); } catch {}
    try {
      const diagnostic = `phase=${error.commitPhase || 'prepare'} resource=${error.resource || ''} source=${error.downloadSource || ''} code=${error.code || 'E_INSTALL'} bytes=${Number.isSafeInteger(error.bytesReceived) ? error.bytesReceived : ''} contentLength=${Number.isSafeInteger(error.contentLength) ? error.contentLength : ''} elapsedMs=${Number.isSafeInteger(error.elapsedMs) ? error.elapsedMs : ''} mirrorResource=${error.mirrorResource || ''} mirrorCode=${error.mirrorCode || ''} mirrorBytes=${Number.isSafeInteger(error.mirrorBytesReceived) ? error.mirrorBytesReceived : ''} mirrorContentLength=${Number.isSafeInteger(error.mirrorContentLength) ? error.mirrorContentLength : ''} mirrorElapsedMs=${Number.isSafeInteger(error.mirrorElapsedMs) ? error.mirrorElapsedMs : ''} syscall=${error.syscall || ''} sourcePath=${error.sourcePath || error.path || ''} destination=${error.destinationPath || error.dest || ''} message=${String(error.message || 'installation failed').replace(/[\r\n\0-\x1f]/g, ' ').slice(0, 1000)}${error.retryCode ? ` retryCode=${error.retryCode}` : ''}${error.retryErrors ? ` retries=${error.retryErrors.map(s => String(s).replace(/[\r\n\0-\x1f]/g, ' ')).join(' | ').slice(0, 600)}` : ''}${error.rollbackMessage ? ` rollbackPhase=${error.rollbackPhase || 'rollback'} rollback=${String(error.rollbackMessage).replace(/[\r\n\0-\x1f]/g, ' ').slice(0, 400)}` : ''}\n`;
      const diagnosticRel = path.join(updateRel, 'diagnostic.txt');
      assertPlainTree(ownedRoot, diagnosticRel, { directory: false, create: true });
      fs.writeFileSync(path.join(ownedRoot, diagnosticRel), diagnostic, { flag: 'wx' });
    } catch {}
    if (error instanceof InstallError) throw error;
    const wrapped = new InstallError(error && error.code || 'E_INSTALL', `${error && error.commitPhase ? `phase=${error.commitPhase}: ` : ''}${error && error.message ? error.message : 'installation failed'}${error && error.retryErrors ? `; retry attempts: ${error.retryErrors.join(' | ')}` : ''}`);
    if (error && error.rollbackMessage) wrapped.rollbackMessage = error.rollbackMessage;
    if (error && error.rollbackPhase) wrapped.rollbackPhase = error.rollbackPhase;
    throw wrapped;
  } finally {
    // Do not remove diagnostics after failure; on success the transaction above removes its staging.
  }
}

function validateInitialRoot(root) {
  if (typeof root !== 'string' || !path.isAbsolute(root)) fail('E_ROOT', 'preparation root must be an absolute path');
  const ownedRoot = path.resolve(root);
  assertPlainTree(ownedRoot, '', { directory: true });
  const markerRel = '.aistick-open-source-preparation.json';
  if (!fs.existsSync(path.join(ownedRoot, markerRel))) fail('E_ROOT_MARKER', 'preparation ownership marker is missing');
  assertPlainTree(ownedRoot, markerRel, { directory: false });
  let marker;
  try { marker = JSON.parse(fs.readFileSync(path.join(ownedRoot, markerRel), 'utf8')); }
  catch { fail('E_ROOT_MARKER', 'preparation ownership marker is invalid'); }
  if (!marker || marker.schema !== 1 || marker.kind !== 'aistick-windows-preparation' || !['running', 'failed'].includes(marker.state)) {
    fail('E_ROOT_MARKER', 'preparation ownership marker does not authorize a first installation');
  }
  for (const rel of ['runtime', 'runtime/node', 'runtime/updates', 'cache', 'npm-global']) {
    assertPlainTree(ownedRoot, rel, { directory: true, create: true });
  }
  const prefix = path.join(ownedRoot, 'npm-global');
  const activeRel = 'npm-global/node_modules/@anthropic-ai/claude-code';
  const shimRel = 'npm-global/claude.cmd';
  const active = path.join(ownedRoot, activeRel);
  const shim = path.join(ownedRoot, shimRel);
  if (fs.existsSync(shim) && !fs.existsSync(active)) fail('E_PREFIX', 'partial Claude installation exists; refusing to overwrite it');
  if (fs.existsSync(active) && fs.existsSync(shim)) {
    const top = fs.readdirSync(prefix).sort();
    if (top.join('|') !== ['claude.cmd', 'node_modules'].join('|')) fail('E_PREFIX', 'npm-global contains unexpected managed-prefix entries');
    const moduleRoot = path.join(prefix, 'node_modules');
    const scopeRoot = path.join(moduleRoot, '@anthropic-ai');
    assertPlainTree(ownedRoot, 'npm-global/node_modules', { directory: true });
    assertPlainTree(ownedRoot, 'npm-global/node_modules/@anthropic-ai', { directory: true });
    if (fs.readdirSync(moduleRoot).join('|') !== '@anthropic-ai' || fs.readdirSync(scopeRoot).join('|') !== 'claude-code') {
      fail('E_PREFIX', 'managed Claude prefix contains unexpected package entries');
    }
    assertPlainTree(ownedRoot, activeRel, { directory: true });
    assertPlainTree(ownedRoot, shimRel, { directory: false });
    const manifest = readManifest(path.join(active, 'package.json'));
    verifyPackageTree(ownedRoot, activeRel, manifest.version);
    if (fs.readFileSync(shim, 'utf8') !== SHIM) fail('E_PREFIX', 'existing Claude command shim is not the expected managed file');
    return { ownedRoot, prefix, activeRel, shimRel, active, shim, alreadyInstalled: manifest.version };
  }
  if (fs.existsSync(active)) {
    assertPlainTree(ownedRoot, activeRel, { directory: true });
    if (fs.readdirSync(active).length !== 0) fail('E_PREFIX', 'partial Claude installation exists; refusing to overwrite it');
    fs.rmdirSync(active);
  }
  const scanPrefix = (dir, rel, depth) => {
    for (const name of fs.readdirSync(dir)) {
      const allowed = depth === 0 ? name === 'node_modules' : depth === 1 ? name === '@anthropic-ai' : false;
      if (!allowed) fail('E_PREFIX', 'npm-global contains unexpected data; refusing to overwrite it');
      const childRel = path.join(rel, name);
      const child = assertPlainTree(ownedRoot, childRel, { directory: true });
      scanPrefix(child, childRel, depth + 1);
    }
  };
  scanPrefix(prefix, 'npm-global', 0);
  assertPlainTree(ownedRoot, 'npm-global/node_modules', { directory: true, create: true });
  assertPlainTree(ownedRoot, 'npm-global/node_modules/@anthropic-ai', { directory: true, create: true });
  return { ownedRoot, prefix, activeRel, shimRel, active, shim, alreadyInstalled: null };
}

async function installInitial(root, options = {}) {
  const layout = validateInitialRoot(root);
  if (layout.alreadyInstalled) return { version: layout.alreadyInstalled, alreadyInstalled: true };
  const { ownedRoot, activeRel, shimRel, active, shim } = layout;
  const updateId = crypto.randomUUID().replace(/-/g, '');
  const updateRel = path.join('cache', `claude-initial-${updateId}`);
  const stageRel = path.join(updateRel, 'stagedClaudePkg');
  const stagePath = path.join(ownedRoot, stageRel);
  const archiveBudget = { compressed: MAX_TOTAL_TARBALL, unpacked: MAX_TOTAL_UNPACKED, entries: MAX_TOTAL_ENTRIES, deadlineAt: Date.now() + TARBALL_BUDGET_MS, officialOnly: true, transport: options.transport, wait: options.wait };
  try {
    const latest = await fetchJson(`https://${REGISTRY}/@anthropic-ai%2Fclaude-code/latest`, options);
    if (!latest || latest.name !== PARENT_NAME || !validateSemver(latest.version)) fail('E_METADATA', 'official registry did not return a stable Claude Code release');
    const parentMeta = validatePackageMetadata(latest, PARENT_NAME, latest.version);
    const platformVersion = latest.optionalDependencies && latest.optionalDependencies[PLATFORM_NAME];
    if (platformVersion !== latest.version) fail('E_METADATA', 'official registry metadata does not pin the matching Windows x64 package version');
    const platformRaw = await fetchJson(`https://${REGISTRY}/@anthropic-ai%2Fclaude-code-win32-x64/${encodeURIComponent(platformVersion)}`, options);
    const platformMeta = validatePackageMetadata(platformRaw, PLATFORM_NAME, platformVersion);
    await downloadAndExtract(parentMeta, PARENT_NAME, latest.version, ownedRoot, stageRel, archiveBudget);
    const platformRel = path.join(stageRel, 'node_modules', '@anthropic-ai', 'claude-code-win32-x64');
    await downloadAndExtract(platformMeta, PLATFORM_NAME, platformVersion, ownedRoot, platformRel, archiveBudget);
    verifyPackageTree(ownedRoot, stageRel, latest.version);

    assertPlainTree(ownedRoot, activeRel, { directory: true, create: true });
    if (fs.readdirSync(active).length !== 0) fail('E_PREFIX', 'Claude destination is not empty');
    fs.rmdirSync(active);
    fs.renameSync(stagePath, active);
    let shimCreated = false;
    try {
      verifyPackageTree(ownedRoot, activeRel, latest.version);
      const shimPath = assertPlainTree(ownedRoot, shimRel, { directory: false, create: true });
      fs.writeFileSync(shimPath, SHIM, { flag: 'wx' }); shimCreated = true;
      if (fs.readFileSync(shim, 'utf8') !== SHIM) fail('E_SHIM', 'installed Claude command shim failed verification');
    } catch (error) {
      if (shimCreated && fs.existsSync(shim)) fs.unlinkSync(shim);
      if (fs.existsSync(active)) removeTreeOwned(ownedRoot, activeRel);
      throw error;
    }
    return { version: latest.version, alreadyInstalled: false };
  } catch (error) {
    try { if (fs.existsSync(path.join(ownedRoot, updateRel))) removeTreeOwned(ownedRoot, updateRel); } catch {}
    throw error;
  }
}

if (require.main === module) {
  const argv = process.argv.slice(2);
  const run = argv[0] === 'initial'
    ? (argv.length === 3 && argv[1] === '--root' ? installInitial(argv[2]) : Promise.reject(new InstallError('E_ARGS', 'initial install requires --root <absolute-path>')))
    : install(argv);
  run.then(({ version, alreadyInstalled }) => {
    process.stdout.write(alreadyInstalled
      ? `Claude Code ${version} is already installed in the managed prefix.\n`
      : `Claude Code ${version} installed in portable prefix.\n`);
  }).catch(error => {
    const code = error && error.code || 'E_INSTALL';
    process.stderr.write(`${code}: ${error && error.message || 'installation failed'}\n`);
    if (error && error.rollbackMessage) process.stderr.write(`rollback${error.rollbackPhase ? ` phase=${error.rollbackPhase}` : ''}: ${error.rollbackMessage}\n`);
    process.exitCode = 1;
  });
}

module.exports = { validateArgs, isSafeSegment, safeTarPath, parseTarGzip, verifyIntegrity, validateLayout, validateInitialRoot, installInitial, parsePeVersion, assertVersions, extractEntries, validatePackageMetadata, verifyPackageTree, commitCandidate, compareStableVersions, requestBuffer, fetchJson, fetchPackageTarball, install, constants: { ROOT_MARKER, PARENT_NAME, PLATFORM_NAME, REGISTRY, MIRROR, MIRROR_CDN, SHIM, DEADLINE_MS, TARBALL_BUDGET_MS, TARBALL_IDLE_MS, MAX_META, MAX_TARBALL, MAX_GET_RETRIES, GET_RETRY_DELAYS_MS } };
