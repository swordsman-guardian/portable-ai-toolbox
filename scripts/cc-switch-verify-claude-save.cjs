'use strict';

// Read-only host-side proof that a save candidate matches the official npm
// archives for its own version. Never launches candidate code.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const installer = require('./cc-switch-portable-claude-install.cjs');

const REGISTRY = 'registry.npmjs.org';
const PARENT = '@anthropic-ai/claude-code';
const PLATFORM = '@anthropic-ai/claude-code-win32-x64';
const MAX_META = 4 * 1024 * 1024;
const MAX_TARBALL = 256 * 1024 * 1024;
const MAX_TOTAL_COMPRESSED = 384 * 1024 * 1024;
const MAX_TOTAL_UNPACKED = 640 * 1024 * 1024;
const MAX_TOTAL_ENTRIES = 60000;
const MAX_TREE_FILES = 60000;
const MAX_TREE_BYTES = 640 * 1024 * 1024;
const MAX_TREE_ENTRIES = 60000;
const MAX_TREE_DEPTH = 128;
const LEGACY = ['claude', 'claude.ps1', 'claude.bash'];

class VerifyError extends Error {
  constructor(code, message) { super(message); this.name = 'VerifyError'; this.code = code; }
}
function fail(code, message) { throw new VerifyError(code, message); }
function stable(v) { return typeof v === 'string' && /^\d+\.\d+\.\d+$/.test(v); }
function isReparse(stat) {
  return stat.isSymbolicLink() || (typeof stat.isReparsePoint === 'function' && stat.isReparsePoint()) ||
    (typeof stat.attributes === 'number' && (stat.attributes & 0x400) !== 0);
}
function plainStat(target, expected) {
  let st;
  try { st = fs.lstatSync(target); }
  catch (e) { if (e.code === 'ENOENT') fail('E_PATH_MISSING', 'candidate or baseline path is missing'); throw e; }
  if (isReparse(st)) fail('E_REPARSE', 'candidate or baseline path contains a reparse point');
  if (expected === 'dir' ? !st.isDirectory() : expected === 'file' ? !st.isFile() : false) fail('E_PATH_TYPE', 'candidate or baseline path has an unexpected type');
  return st;
}
function absolutePlainPath(input, expected) {
  if (typeof input !== 'string' || !path.isAbsolute(input) || input.includes('\0')) fail('E_ARGS', 'candidate and baseline must be absolute paths');
  const full = path.resolve(input);
  const parsed = path.parse(full);
  if (!parsed.root) fail('E_ARGS', 'path root is invalid');
  let current = parsed.root;
  plainStat(current, 'dir');
  for (const part of full.slice(parsed.root.length).split(/[\\/]/).filter(Boolean)) {
    if (!installer.isSafeSegment(part)) fail('E_PATH', 'candidate and baseline path contains an unsafe component');
    current = path.join(current, part);
    plainStat(current, current.toLowerCase() === full.toLowerCase() ? expected : 'dir');
  }
  return full;
}
function validChildName(name) {
  return installer.isSafeSegment(name) && !/[\u0000-\u001f]/.test(name);
}
function hashBuffer(buffer) { return crypto.createHash('sha256').update(buffer).digest('hex'); }
function readRegularFile(file, maxBytes = MAX_TREE_BYTES) {
  const st = plainStat(file, 'file');
  if (st.size > maxBytes) fail('E_TREE_LIMIT', 'candidate file exceeds the size limit');
  const data = fs.readFileSync(file);
  if (data.length !== st.size) fail('E_TREE_CHANGED', 'candidate file changed while being read');
  return data;
}

function readCandidateVersion(candidateRoot) {
  const manifestPath = path.join(candidateRoot, 'node_modules', '@anthropic-ai', 'claude-code', 'package.json');
  absolutePlainPath(manifestPath, 'file');
  const data = readRegularFile(manifestPath, 1024 * 1024);
  let manifest;
  try { manifest = JSON.parse(data.toString('utf8')); } catch { fail('E_CANDIDATE', 'candidate Claude package manifest is invalid'); }
  if (!manifest || manifest.name !== PARENT || !stable(manifest.version)) fail('E_CANDIDATE', 'candidate is not a stable official Claude package');
  return manifest.version;
}

function buildExpectedTree(parentArchive, platformArchive, version) {
  if (!stable(version)) fail('E_VERSION', 'candidate Claude version is invalid');
  const parentEntries = installer.parseTarGzip(parentArchive, { maxCompressed: MAX_TARBALL, maxUnpacked: MAX_TOTAL_UNPACKED, maxEntries: MAX_TOTAL_ENTRIES });
  const parentExpanded = parentEntries.reduce((n, e) => n + (e.type === 'file' ? e.data.length : 0), 0);
  if (parentExpanded > MAX_TOTAL_UNPACKED || parentEntries.length > MAX_TOTAL_ENTRIES) fail('E_ARCHIVE_LIMIT', 'official parent archive exceeds combined limits');
  const platformEntries = installer.parseTarGzip(platformArchive, { maxCompressed: MAX_TARBALL, maxUnpacked: MAX_TOTAL_UNPACKED - parentExpanded, maxEntries: MAX_TOTAL_ENTRIES - parentEntries.length });
  const expected = new Map();
  let bytes = 0, count = 0;
  function insert(relative, type, data) {
    if (!relative) return;
    const pieces = relative.split('/');
    for (let i = 1; i <= pieces.length; i++) {
      const key = pieces.slice(0, i).join('/');
      const final = i === pieces.length;
      const entryType = final ? type : 'directory';
      const value = final && type === 'file' ? { type: 'file', size: data.length, sha256: hashBuffer(data) } : { type: 'directory' };
      const existing = expected.get(key.toLocaleLowerCase('en-US'));
      if (existing) {
        if (existing.path !== key) fail('E_OFFICIAL_TREE', 'official package archives contain a case collision');
        if (final && existing.explicit) {
          if (existing.type !== value.type || existing.type === 'file' && (existing.size !== value.size || existing.sha256 !== value.sha256)) fail('E_OFFICIAL_TREE', 'official archives contain conflicting package entries');
          return;
        }
        if (entryType === 'file' && existing.type === 'directory') fail('E_OFFICIAL_TREE', 'official archive entry conflicts with a directory');
        if (entryType === 'directory' && existing.type === 'file') fail('E_OFFICIAL_TREE', 'official archive entry conflicts with a file');
      }
      expected.set(key.toLocaleLowerCase('en-US'), { ...value, path: key, explicit: final });
    }
    if (type === 'file') { bytes += data.length; count++; }
    if (bytes > MAX_TOTAL_UNPACKED || count > MAX_TOTAL_ENTRIES) fail('E_ARCHIVE_LIMIT', 'official expanded package exceeds combined limits');
  }
  function add(entries, base) {
    for (const e of entries) {
      const suffix = e.path.split('/').slice(1).join('/');
      if (!suffix) continue;
      insert(base ? `${base}/${suffix}` : suffix, e.type, e.data);
    }
  }
  add(parentEntries, '');
  add(platformEntries, 'node_modules/@anthropic-ai/claude-code-win32-x64');
  const parentManifest = expected.get('package.json');
  const platformManifest = expected.get('node_modules/@anthropic-ai/claude-code-win32-x64/package.json');
  if (!parentManifest || parentManifest.type !== 'file' || !platformManifest || platformManifest.type !== 'file') fail('E_OFFICIAL_TREE', 'official package archives are missing manifests');
  function findEntry(entries, wanted) {
    return entries.find(e => e.path === `package/${wanted}` && e.type === 'file');
  }
  const pm = JSON.parse(findEntry(parentEntries, 'package.json').data.toString('utf8'));
  const xm = JSON.parse(findEntry(platformEntries, 'package.json').data.toString('utf8'));
  if (!pm || pm.name !== PARENT || pm.version !== version || !xm || xm.name !== PLATFORM || xm.version !== version) fail('E_OFFICIAL_TREE', 'official archive package identity does not match requested version');
  const peEntry = findEntry(platformEntries, 'claude.exe');
  if (!peEntry) fail('E_OFFICIAL_TREE', 'official Windows package has no Claude executable');
  installer.assertVersions(installer.parsePeVersion(peEntry.data), version, version);
  for (const [key, item] of expected) expected.set(key, { path: item.path, type: item.type, size: item.size, sha256: item.sha256 });
  return { expected, bytes, files: count };
}

function scanFileTree(root, { maximumFiles = MAX_TREE_FILES, maximumBytes = MAX_TREE_BYTES, maximumEntries = MAX_TREE_ENTRIES, maximumDepth = MAX_TREE_DEPTH } = {}) {
  const entries = new Map();
  let fileCount = 0, byteCount = 0, entryCount = 0;
  const visit = (full, relative, depth) => {
    if (depth > maximumDepth) fail('E_TREE_LIMIT', 'candidate tree exceeds maximum depth');
    const st = plainStat(full, '');
    if (st.isDirectory()) {
      if (relative) {
        if (++entryCount > maximumEntries) fail('E_TREE_LIMIT', 'candidate tree exceeds entry count limit');
        const key = relative.toLocaleLowerCase('en-US');
        if (entries.has(key)) fail('E_TREE_COLLISION', 'candidate tree has duplicate or case-colliding paths');
        entries.set(key, { path: relative, type: 'directory' });
      }
      const children = fs.readdirSync(full);
      for (const name of children) {
        if (!validChildName(name)) fail('E_PATH', 'candidate tree contains an unsafe filename');
        const childRelative = relative ? `${relative}/${name}` : name;
        visit(path.join(full, name), childRelative, depth + 1);
      }
    } else if (st.isFile()) {
      if (!relative) fail('E_TREE', 'candidate tree root cannot be a file');
      if (++entryCount > maximumEntries) fail('E_TREE_LIMIT', 'candidate tree exceeds entry count limit');
      fileCount++; byteCount += st.size;
      if (fileCount > maximumFiles || byteCount > maximumBytes || st.size > maximumBytes) fail('E_TREE_LIMIT', 'candidate tree exceeds count or size limits');
      const data = readRegularFile(full, maximumBytes);
      const key = relative.toLocaleLowerCase('en-US');
      if (entries.has(key)) fail('E_TREE_COLLISION', 'candidate tree has duplicate or case-colliding paths');
      entries.set(key, { path: relative, type: 'file', size: data.length, sha256: hashBuffer(data) });
    } else fail('E_PATH_TYPE', 'candidate tree contains a special filesystem entry');
  };
  visit(root, '', 0);
  return { entries, fileCount, byteCount };
}

function comparePackageTree(candidateRoot, expectedTree) {
  const packageRoot = path.join(candidateRoot, 'node_modules', '@anthropic-ai', 'claude-code');
  absolutePlainPath(packageRoot, 'dir');
  const actual = scanFileTree(packageRoot);
  const expected = expectedTree.expected;
  for (const [key, want] of expected) {
    const got = actual.entries.get(key);
    if (!got) fail('E_TREE_MISSING', `candidate package is missing ${want.path}`);
    if (got.path !== want.path) fail('E_TREE_PATH', `candidate package path differs from official archive at ${want.path}`);
    if (got.type !== want.type) fail('E_TREE_TYPE', `candidate package entry type differs at ${want.path}`);
    if (want.type === 'file' && (got.size !== want.size || got.sha256 !== want.sha256)) fail('E_TREE_CONTENT', `candidate package content differs at ${want.path}`);
  }
  for (const [key, got] of actual.entries) if (!expected.has(key)) fail('E_TREE_EXTRA', `candidate package contains unapproved entry ${got.path}`);
  return actual;
}

function compareTopLevel(candidateRoot, baselineRoot) {
  const candidateNames = fs.readdirSync(candidateRoot);
  const baselineNames = new Set(fs.readdirSync(baselineRoot));
  const allowed = new Set(['node_modules', 'claude.cmd']);
  for (const name of LEGACY) if (baselineNames.has(name)) allowed.add(name);
  for (const name of candidateNames) {
    if (!validChildName(name)) fail('E_TOP_LEVEL', 'candidate slot has an unsafe top-level name');
    const target = path.join(candidateRoot, name);
    const st = plainStat(target, '');
    if (isReparse(st)) fail('E_REPARSE', 'candidate top-level entry is a reparse point');
    if (!allowed.has(name)) fail('E_TOP_LEVEL', `candidate slot contains unapproved top-level entry ${name}`);
    if (name === 'node_modules' ? !st.isDirectory() : !st.isFile()) fail('E_TOP_LEVEL', `candidate top-level entry ${name} has the wrong type`);
  }
  if (!candidateNames.includes('node_modules') || !candidateNames.includes('claude.cmd')) fail('E_TOP_LEVEL', 'candidate slot is missing node_modules or claude.cmd');
  const scopes = fs.readdirSync(path.join(candidateRoot, 'node_modules'));
  if (scopes.length !== 1 || scopes[0] !== '@anthropic-ai') fail('E_TOP_LEVEL', 'candidate node_modules contains unapproved packages');
  const packages = fs.readdirSync(path.join(candidateRoot, 'node_modules', '@anthropic-ai'));
  if (packages.length !== 1 || packages[0] !== 'claude-code') fail('E_TOP_LEVEL', 'candidate Anthropic scope contains unapproved packages');
  for (const name of LEGACY) {
    const candidatePath = path.join(candidateRoot, name);
    const baselinePath = path.join(baselineRoot, name);
    const inCandidate = candidateNames.includes(name);
    const inBaseline = baselineNames.has(name);
    if (inCandidate && !inBaseline) fail('E_LEGACY', `candidate added untrusted wrapper ${name}`);
    if (inBaseline && inCandidate) {
      const baselineData = readRegularFile(baselinePath, 4 * 1024 * 1024);
      const candidateData = readRegularFile(candidatePath, 4 * 1024 * 1024);
      if (!candidateData.equals(baselineData)) fail('E_LEGACY', `candidate wrapper differs from trusted baseline: ${name}`);
    }
  }
  const shim = readRegularFile(path.join(candidateRoot, 'claude.cmd'), 64 * 1024);
  const trustedShim = installer.constants.SHIM;
  const baselineShimPath = path.join(baselineRoot, 'claude.cmd');
  let baselineShim = null;
  try { baselineShim = readRegularFile(baselineShimPath, 64 * 1024); }
  catch (e) { if (!(e instanceof VerifyError) || e.code !== 'E_PATH_MISSING') throw e; }
  if (!shim.equals(Buffer.from(trustedShim, 'utf8')) && (!baselineShim || !shim.equals(baselineShim))) fail('E_SHIM', 'candidate claude.cmd differs from the official or trusted baseline shim');
}

function verifyCandidateWithArchives(candidateInput, baselineInput, parentMeta, platformMeta, parentArchive, platformArchive) {
  const candidateRoot = absolutePlainPath(candidateInput, 'dir');
  const baselineRoot = absolutePlainPath(baselineInput, 'dir');
  const version = readCandidateVersion(candidateRoot);
  const pm = installer.validatePackageMetadata(parentMeta, PARENT, version);
  const platformVersion = parentMeta.optionalDependencies && parentMeta.optionalDependencies[PLATFORM];
  if (platformVersion !== version) fail('E_METADATA', 'official parent metadata does not pin the matching Windows x64 version');
  const xm = installer.validatePackageMetadata(platformMeta, PLATFORM, version);
  if (parentMeta.version !== version || xm.version !== version) fail('E_METADATA', 'official metadata version mismatch');
  const pBytes = Buffer.isBuffer(parentArchive) ? parentArchive : Buffer.from(parentArchive);
  const xBytes = Buffer.isBuffer(platformArchive) ? platformArchive : Buffer.from(platformArchive);
  if (pBytes.length + xBytes.length > MAX_TOTAL_COMPRESSED || pBytes.length > MAX_TARBALL || xBytes.length > MAX_TARBALL) fail('E_ARCHIVE_LIMIT', 'official downloads exceed combined compressed size limit');
  installer.verifyIntegrity(pBytes, pm.dist.integrity, pm.dist.shasum);
  installer.verifyIntegrity(xBytes, xm.dist.integrity, xm.dist.shasum);
  const tree = buildExpectedTree(pBytes, xBytes, version);
  comparePackageTree(candidateRoot, tree);
  compareTopLevel(candidateRoot, baselineRoot);
  return { version };
}

async function verifyCandidate(candidate, baseline, networkOptions = {}) {
  const candidateRoot = absolutePlainPath(candidate, 'dir');
  const baselineRoot = absolutePlainPath(baseline, 'dir');
  const version = readCandidateVersion(candidateRoot);
  const parentMeta = await installer.fetchJson(`https://${REGISTRY}/@anthropic-ai%2Fclaude-code/${encodeURIComponent(version)}`, networkOptions);
  if (!parentMeta || parentMeta.name !== PARENT || parentMeta.version !== version) fail('E_METADATA', 'official Claude metadata did not match candidate version');
  if (!parentMeta.optionalDependencies || parentMeta.optionalDependencies[PLATFORM] !== version) fail('E_METADATA', 'official Claude metadata has no matching Windows x64 package');
  const platformMeta = await installer.fetchJson(`https://${REGISTRY}/@anthropic-ai%2Fclaude-code-win32-x64/${encodeURIComponent(version)}`, networkOptions);
  installer.validatePackageMetadata(parentMeta, PARENT, version);
  installer.validatePackageMetadata(platformMeta, PLATFORM, version);
  const archiveDeadlineAt = Date.now() + installer.constants.TARBALL_BUDGET_MS;
  const parentArchive = await installer.fetchPackageTarball(parentMeta, PARENT, version, {
    ...networkOptions, maxBytes: Math.min(MAX_TARBALL, MAX_TOTAL_COMPRESSED), deadlineAt: archiveDeadlineAt,
  });
  const platformArchive = await installer.fetchPackageTarball(platformMeta, PLATFORM, version, {
    ...networkOptions, maxBytes: Math.min(MAX_TARBALL, MAX_TOTAL_COMPRESSED - parentArchive.length), deadlineAt: archiveDeadlineAt,
  });
  return verifyCandidateWithArchives(candidateRoot, baselineRoot, parentMeta, platformMeta, parentArchive, platformArchive);
}

function parseArgs(args) {
  if (!Array.isArray(args) || args.length !== 4 || args[0] !== '--candidate' || args[2] !== '--baseline') fail('E_ARGS', 'expected --candidate ABS --baseline ABS');
  if (!path.isAbsolute(args[1]) || !path.isAbsolute(args[3])) fail('E_ARGS', 'candidate and baseline must be absolute paths');
  return { candidate: args[1], baseline: args[3] };
}

if (require.main === module) {
  try {
    const { candidate, baseline } = parseArgs(process.argv.slice(2));
    verifyCandidate(candidate, baseline).then(({ version }) => {
      process.stdout.write(`Claude Code ${version} verified for save.\n`);
    }).catch(error => {
      process.stderr.write(`${error.code || 'E_VERIFY'}: ${String(error.message || 'verification failed').replace(/[\r\n\0-\x1f]/g, ' ').slice(0, 600)}\n`);
      process.exitCode = 1;
    });
  } catch (error) {
    process.stderr.write(`${error.code || 'E_VERIFY'}: ${String(error.message || 'verification failed').replace(/[\r\n\0-\x1f]/g, ' ').slice(0, 600)}\n`);
    process.exitCode = 1;
  }
}

module.exports = { parseArgs, buildExpectedTree, scanFileTree, comparePackageTree, compareTopLevel, verifyCandidateWithArchives, verifyCandidate, constants: { REGISTRY, PARENT, PLATFORM, MAX_TARBALL, MAX_TOTAL_COMPRESSED, MAX_TOTAL_UNPACKED, MAX_TOTAL_ENTRIES, TARBALL_BUDGET_MS: installer.constants.TARBALL_BUDGET_MS } };
