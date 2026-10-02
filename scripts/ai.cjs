#!/usr/bin/env node
'use strict';

// One physical USB interface for Windows and Linux. Windows remains delegated
// to its established PowerShell launcher; Linux uses only the toolbox modules.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');

function windowsInvocation(args) {
  if (args.includes('--diagnose')) return { file: path.join(root, 'scripts', 'diagnose-cc-switch-claude.ps1'), args: [] };
  return { file: path.join(root, 'scripts', 'launch.ps1'), args: args.includes('--settings') ? ['-Config'] : args };
}

function fixedPowerShell(args) {
  const exe = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  if (!fs.existsSync(exe)) throw new Error('Windows PowerShell is unavailable at its fixed system path.');
  const invocation = windowsInvocation(args);
  const result = spawnSync(exe, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', invocation.file, ...invocation.args], { stdio: 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  return result.status == null ? 1 : result.status;
}

async function main(argv = process.argv.slice(2)) {
  if (process.platform === 'win32') return fixedPowerShell(argv);
  if (process.platform !== 'linux') throw new Error(`This toolbox supports Windows and Linux; detected ${process.platform}.`);
  const { runCli } = require('./linux-session.cjs');
  return runCli({ root, mode: argv.includes('--diagnose') ? 'diagnose' : argv.includes('--settings') ? 'settings' : 'main' });
}

if (require.main === module) main().then((code) => { process.exitCode = Number(code) || 0; }).catch((error) => { console.error(`Toolbox error: ${error.message}`); process.exitCode = 1; });

module.exports = { main, fixedPowerShell, windowsInvocation };
