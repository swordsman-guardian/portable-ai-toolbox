'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const api = require('./linux-native-proxy.cjs');
async function main() {
  if (process.platform !== 'linux') { console.log('Linux native proxy ownership test requires /proc (skipped on this OS).'); return; }
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-native-proxy-'));
  fs.chmodSync(root, 0o700);
  let state, child, hostListener;
  const provider = { mode: 'proxy-managed', secret: null, baseUrl: null, models: { ANTHROPIC_MODEL: 'synthetic' } };
  try {
    state = await api.prepareNativeProxy({ sessionRoot: root, network: true });
    assert.notEqual(state.port, 15721);
    await api.releaseReservation(state);
    const { DatabaseSync } = require('node:sqlite'); const db = new DatabaseSync(state.dbPath);
    db.exec('UPDATE proxy_config SET proxy_enabled=1'); db.close();
    const sibling = net.createServer(); await new Promise(resolve => sibling.listen(state.port, '127.0.0.1', resolve)); hostListener = sibling;
    child = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { stdio: 'ignore' });
    api.attachManager(state, child.pid);
    await assert.rejects(api.asNativeProvider(state, provider, child.pid), /监听进程/);
    await new Promise(resolve => sibling.close(resolve)); hostListener = null;
    child.kill(); await new Promise(resolve => child.once('exit', resolve));
    child = spawn(process.execPath, ['-e', `require('node:net').createServer().listen(${state.port},'127.0.0.1',()=>process.stdout.write('READY'))`], { stdio: ['ignore', 'pipe', 'ignore'] });
    api.attachManager(state, child.pid);
    await new Promise((resolve, reject) => { child.stdout.once('data', resolve); child.once('error', reject); child.once('exit', () => reject(Error('owned listener exited early'))); });
    const managed = await api.asNativeProvider(state, provider, child.pid);
    assert.equal(managed.baseUrl, `http://127.0.0.1:${state.port}`); assert.equal(managed.secret, 'PROXY_MANAGED');
    child.kill(); await new Promise(resolve => child.once('exit', resolve));
    const listenerCode = `require('node:net').createServer().listen(${state.port},'127.0.0.1',()=>process.stdout.write('READY'))`;
    const managerCode = `const {spawn}=require('node:child_process');const listener=spawn(process.execPath,['-e',${JSON.stringify(listenerCode)}],{stdio:['ignore','pipe','ignore']});listener.stdout.pipe(process.stdout);process.on('SIGTERM',()=>{listener.kill();process.exit()});setInterval(()=>{},1000)`;
    child = spawn(process.execPath, ['-e', managerCode], { stdio: ['ignore', 'pipe', 'ignore'] });
    api.attachManager(state, child.pid);
    await new Promise((resolve, reject) => { child.stdout.once('data', resolve); child.once('error', reject); child.once('exit', () => reject(Error('descendant listener exited early'))); });
    const descendantManaged = await api.asNativeProvider(state, provider, child.pid);
    assert.equal(descendantManaged.baseUrl, `http://127.0.0.1:${state.port}`);
    api.restorePortableProxySettings(state);
    const readback = new DatabaseSync(state.dbPath, { readOnly: true });
    assert.equal(readback.prepare("SELECT listen_port FROM proxy_config WHERE app_type='claude'").get().listen_port, 15721);
    assert.equal(readback.prepare("SELECT proxy_enabled FROM proxy_config WHERE app_type='claude'").get().proxy_enabled, 1);
    readback.close();
    await api.closeNativeProxy(state);
    await assert.rejects(api.asNativeProvider(state, provider, child.pid), /联网/);
    console.log('PASS: per-session native proxy port, host-listener rejection, manager and descendant owned listeners, closed manager rejection');
  } finally {
    if (hostListener) hostListener.close(); if (state) await api.closeNativeProxy(state);
    if (child?.exitCode === null) { child.kill('SIGKILL'); await new Promise(resolve => child.once('exit', resolve)); }
    fs.rmSync(root, { recursive: true, force: true });
  }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
