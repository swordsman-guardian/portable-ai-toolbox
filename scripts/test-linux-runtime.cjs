'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { prepareRuntime, stageRuntime, exportClaudeRuntime, status, HASH_PATHS } = require('./linux-runtime.cjs');

function makeStatusFixture(dir) {
  const crypto = require('node:crypto');
  const hashes = {};
  for (const rel of HASH_PATHS) {
    const p = path.join(dir, rel); fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, rel); hashes[rel] = crypto.createHash('sha256').update(rel).digest('hex');
  }
  const archive = path.join(dir, 'npm-global/linux-x64/slots/1.0.0-123456789abc/claude-package.tar.gz');
  fs.mkdirSync(path.dirname(archive), { recursive: true }); fs.writeFileSync(archive, 'claude');
  const archiveSha256 = crypto.createHash('sha256').update('claude').digest('hex');
  const meta = { name: '@anthropic-ai/claude-code', version: '1.0.0', archiveSha256, registryIntegrity: null };
  fs.writeFileSync(path.join(path.dirname(archive), 'manifest.json'), JSON.stringify(meta));
  fs.writeFileSync(path.join(dir, 'npm-global/linux-x64/active.json'), JSON.stringify({ slot: 'slots/1.0.0-123456789abc', version: '1.0.0', archiveSha256 }));
  fs.writeFileSync(path.join(dir, 'runtime/linux-x64/manifest.json'), JSON.stringify({ platform: 'linux', arch: 'x64', versions: { node: '22.23.3', uv: '0.8.22', ccSwitch: '3.20.4' }, sha256: hashes }));
}
function checkManifestRejects() {
  const t = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-linux-manifest-'));
  try {
    const root = path.join(t, 'root'); fs.mkdirSync(root); makeStatusFixture(root);
    const manifestPath = path.join(root, 'runtime/linux-x64/manifest.json');
    const valid = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    assert.equal(status(root).integrity, false, 'fixture must fail the official AppImage digest pin unless it contains the release asset');
    const empty = { ...valid, sha256: {} }; fs.writeFileSync(manifestPath, JSON.stringify(empty));
    assert.equal(status(root).ready, false, 'empty hash manifest must fail closed');
    const partial = { ...valid, sha256: { ...valid.sha256 } }; delete partial.sha256[HASH_PATHS[0]];
    fs.writeFileSync(manifestPath, JSON.stringify(partial)); assert.equal(status(root).ready, false, 'partial hash manifest must fail closed');
    const traversal = { ...valid, sha256: { ...valid.sha256, '../escape': '0'.repeat(64) } };
    fs.writeFileSync(manifestPath, JSON.stringify(traversal)); assert.equal(status(root).ready, false, 'noncanonical manifest paths must fail closed');
    fs.writeFileSync(manifestPath, JSON.stringify(valid));
    const replaced = path.join(root, HASH_PATHS[0]); fs.unlinkSync(replaced); fs.symlinkSync(path.join(t, 'outside'), replaced); fs.writeFileSync(path.join(t, 'outside'), 'outside');
    assert.equal(status(root).ready, false, 'asset symlinks must fail closed');
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
}

function checkClaudeExport() {
  const t = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-linux-export-'));
  try {
    const root = path.join(t, 'root'); const session = path.join(t, 'session');
    const prefix = path.join(session, 'npm'); const pkg = path.join(prefix, 'lib/node_modules/@anthropic-ai/claude-code');
    fs.mkdirSync(pkg, { recursive: true }); fs.mkdirSync(path.join(prefix, 'bin'), { recursive: true });
    fs.mkdirSync(path.join(pkg, 'bin'), { recursive: true });
    fs.writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({ name: '@anthropic-ai/claude-code', version: '9.8.7', bin: { claude: 'bin/claude.exe' } }));
    fs.writeFileSync(path.join(pkg, 'bin/claude.exe'), 'portable native placeholder'); fs.chmodSync(path.join(pkg, 'bin/claude.exe'), 0o755);
    fs.symlinkSync('../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe', path.join(prefix, 'bin/claude'));
    fs.symlinkSync('/outside/node', path.join(prefix, 'bin/node'));
    const native = path.join(prefix, 'lib/node_modules/@anthropic-ai/claude-code-linux-x64');
    fs.mkdirSync(native, { recursive: true }); fs.writeFileSync(path.join(native, 'package.json'), '{"name":"@anthropic-ai/claude-code-linux-x64"}');
    fs.mkdirSync(path.join(session, 'cache/npm'), { recursive: true });
    fs.writeFileSync(path.join(session, 'private-settings.json'), 'never export');
    const result = exportClaudeRuntime(root, session);
    assert.equal(result.version, '9.8.7');
    const active = JSON.parse(fs.readFileSync(path.join(root, 'npm-global/linux-x64/active.json'), 'utf8'));
    assert.equal(active.archiveSha256, result.sha256);
    assert.equal(fs.readFileSync(path.join(root, 'npm-global/linux-x64', active.slot, 'manifest.json'), 'utf8').includes('private-settings'), false);
    const listing = spawnSync('/usr/bin/tar', ['-tzf', path.join(root, 'npm-global/linux-x64', active.slot, 'claude-package.tar.gz')], { encoding: 'utf8' });
    assert.equal(listing.status, 0);
    assert.match(listing.stdout, /package\/bin\/claude/);
    assert.match(listing.stdout, /package\/lib\/node_modules\/\@anthropic-ai\/claude-code\/package.json/);
    assert.match(listing.stdout, /package\/lib\/node_modules\/\@anthropic-ai\/claude-code-linux-x64\/package.json/);
    assert.doesNotMatch(listing.stdout, /(?:^|\/)bin\/(?:node|npm)(?:\n|$)/m);
    assert.doesNotMatch(listing.stdout, /private-settings|cache/);
    assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'npm-global/linux-x64', active.slot, 'manifest.json'), 'utf8')).registryIntegrity, null);
  } finally { fs.rmSync(t, { recursive: true, force: true }); }
}

function main() {
  checkManifestRejects();
  checkClaudeExport();
  if (process.argv.includes('--unit-only')) return;
  const root = path.resolve(process.argv[2] || process.env.AISTICK_ROOT || '..');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-linux-stage-'));
  try {
    const state = prepareRuntime(root, { arch: 'x64' });
    assert.equal(state.ready, true, `runtime incomplete: ${state.missing.join(', ')}`);
    assert.equal(state.integrity, true);
    assert.equal(state.versions.ccSwitch, '3.20.4');
    const staged = stageRuntime(root, path.join(temp, 'session'));
    assert.match(staged.nodeVersion, /^v22\./);
    assert.match(staged.uvVersion, /^uv /);
    assert.match(staged.pythonVersion, /^Python 3\.12\./);
    assert.equal(fs.statSync(staged.git).isFile(), true);
    assert.equal(fs.statSync(staged.bwrap).isFile(), true);
    assert.equal(fs.statSync(staged.ccSwitch).isFile(), true);
    assert.equal(fs.existsSync(staged.claude), true);
    const active = JSON.parse(fs.readFileSync(path.join(root, 'npm-global/linux-x64/active.json'), 'utf8'));
    const npmManifest = JSON.parse(fs.readFileSync(path.join(root, 'npm-global/linux-x64', active.slot, 'manifest.json'), 'utf8'));
    assert.equal(npmManifest.name, '@anthropic-ai/claude-code');
    assert.match(npmManifest.registryIntegrity, /^sha512-/);
    process.stdout.write(`runtime staged: Node ${staged.nodeVersion}; ${staged.pythonVersion}; Claude ${npmManifest.version}\n`);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}
try { main(); } catch (e) { process.stderr.write(`${e.stack || e}\n`); process.exitCode = 1; }
