'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { windowsInvocation, fixedPowerShell } = require('./ai.cjs');

const settings = windowsInvocation(['--settings']);
assert.equal(path.basename(settings.file), 'launch.ps1');
assert.deepEqual(settings.args, ['-Config']);
const diagnose = windowsInvocation(['--diagnose']);
assert.equal(path.basename(diagnose.file), 'diagnose-cc-switch-claude.ps1');
assert.deepEqual(diagnose.args, []);
const ordinary = windowsInvocation(['C:\\work']);
assert.equal(path.basename(ordinary.file), 'launch.ps1');
assert.deepEqual(ordinary.args, ['C:\\work']);
const previousRoot = process.env.SystemRoot;
try {
  process.env.SystemRoot = require('node:os').tmpdir();
  assert.throws(() => fixedPowerShell([]), /fixed system path/, 'Windows dispatch must not fall back to a PATH-controlled executable');
} finally {
  if (previousRoot === undefined) delete process.env.SystemRoot; else process.env.SystemRoot = previousRoot;
}
console.log('Linux/Windows launcher routing checks passed.');
