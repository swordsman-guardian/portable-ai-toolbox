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
    const scope = path.join(prefix, 'lib/node_modules/@anthropic-ai');
    const fingerprint = (base) => {
      const entries = []; const todo = [base];
      while (todo.length) {
        const dir = todo.pop();
        for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
          const p = path.join(dir, ent.name); const rel = path.relative(base, p).split(path.sep).join('/'); const st = fs.lstatSync(p);
          if (st.isSymbolicLink()) entries.push({ path: rel, type: 'link', target: fs.readlinkSync(p) });
          else if (st.isDirectory()) { entries.push({ path: rel, type: 'directory' }); todo.push(p); }
          else entries.push({ path: rel, type: 'file', executable: st.mode & 0o111, size: st.size, sha256: require('node:crypto').createHash('sha256').update(fs.readFileSync(p)).digest('hex') });
        }
      }
      entries.sort((a, b) => a.path.localeCompare(b.path));
      return require('node:crypto').createHash('sha256').update(JSON.stringify(entries)).digest('hex');
    };
    // Same-version content updates must export even when no staging baseline
    // exists (the compatibility path used by direct exports and old sessions).
    fs.writeFileSync(path.join(pkg, 'new-runtime-file.js'), 'changed package bytes');
    const updated = exportClaudeRuntime(root, session);
    assert.equal(updated.version, '9.8.7');
    assert.notEqual(updated.sha256, result.sha256, 'same-version byte updates must create a new immutable slot');
    const activePath = path.join(root, 'npm-global/linux-x64/active.json');
    const updatedActive = JSON.parse(fs.readFileSync(activePath, 'utf8'));
    const slotsRoot = path.join(root, 'npm-global/linux-x64/slots');
    const slotsBefore = fs.readdirSync(slotsRoot).sort();
    const pointerBefore = fs.readFileSync(activePath);
    const pointerMtimeBefore = fs.statSync(activePath).mtimeMs;
    const archivePath = path.join(root, 'npm-global/linux-x64', updatedActive.slot, 'claude-package.tar.gz');
    const archiveMtimeBefore = fs.statSync(archivePath).mtimeMs;
    const originPath = path.join(session, '.claude-origin.json');
    fs.writeFileSync(originPath, JSON.stringify({ active: updatedActive, scopeFingerprint: fingerprint(scope) }), { mode: 0o600 });
    const unchanged = exportClaudeRuntime(root, session);
    assert.equal(unchanged.unchanged, true);
    assert.deepEqual(fs.readdirSync(slotsRoot).sort(), slotsBefore, 'unchanged round trip must not create another slot');
    assert.deepEqual(fs.readFileSync(activePath), pointerBefore, 'unchanged round trip must preserve active pointer bytes');
    assert.equal(fs.statSync(activePath).mtimeMs, pointerMtimeBefore, 'unchanged round trip must not rewrite active pointer');
    assert.equal(fs.statSync(archivePath).mtimeMs, archiveMtimeBefore, 'unchanged round trip must not touch the active slot');
    // A different session that started from the prior pointer must not publish
    // its stale package over an active pointer that has since advanced.
    fs.writeFileSync(originPath, JSON.stringify({ active, scopeFingerprint: fingerprint(scope) }), { mode: 0o600 });
    assert.throws(() => exportClaudeRuntime(root, session), /refusing stale Claude runtime export/);
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
    const pointerPath = path.join(root, 'npm-global/linux-x64/active.json');
    const pointerBytes = fs.readFileSync(pointerPath); const pointerMtime = fs.statSync(pointerPath).mtimeMs;
    const slotsDir = path.join(root, 'npm-global/linux-x64/slots'); const slotNames = fs.readdirSync(slotsDir).sort();
    const archivePath = path.join(root, 'npm-global/linux-x64', active.slot, 'claude-package.tar.gz'); const slotMtime = fs.statSync(archivePath).mtimeMs;
    const noChange = exportClaudeRuntime(root, staged.sessionRoot);
    assert.equal(noChange.unchanged, true, 'staged unmodified Claude runtime should be a no-op export');
    assert.deepEqual(fs.readFileSync(pointerPath), pointerBytes);
    assert.equal(fs.statSync(pointerPath).mtimeMs, pointerMtime);
    assert.equal(fs.statSync(archivePath).mtimeMs, slotMtime);
    assert.deepEqual(fs.readdirSync(slotsDir).sort(), slotNames);
    const npmManifest = JSON.parse(fs.readFileSync(path.join(root, 'npm-global/linux-x64', active.slot, 'manifest.json'), 'utf8'));
    assert.equal(npmManifest.name, '@anthropic-ai/claude-code');
    assert.match(npmManifest.registryIntegrity, /^sha512-/);
    process.stdout.write(`runtime staged: Node ${staged.nodeVersion}; ${staged.pythonVersion}; Claude ${npmManifest.version}\n`);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}
try { main(); } catch (e) { process.stderr.write(`${e.stack || e}\n`); process.exitCode = 1; }
