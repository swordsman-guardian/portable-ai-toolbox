'use strict';

// Node core-only implementation of cc-switch-encrypted-store.ps1's on-disk format.
// Plain snapshots exist only in process memory; USB files are authenticated ciphertext.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const net = require('node:net');

const FORMAT = 'cc-switch-encrypted-generation-v1';
const ARCHIVE_FORMAT = 'cc-switch-encrypted-archive-v1';
const VAULT = 'portable-credential-vault';
const ITERATIONS = 600000;
const MAX_PLAIN = 32 * 1024 * 1024, MAX_CIPHER = 48 * 1024 * 1024;
const MAX_ARCHIVE = 256 * 1024 * 1024;
const MAX_FILES = 2048, MAX_ENTRIES = 4096, MAX_DEPTH = 64, MAX_PATH = 240;
const utf8 = new TextDecoder('utf-8', { fatal: true });

function storePath(root) { return path.join(path.resolve(root), 'config', 'cc-switch', 'secure-store'); }
function hash(b) { return crypto.createHash('sha256').update(b).digest('hex'); }
function secureEq(a, b) { return a.length === b.length && crypto.timingSafeEqual(a, b); }
function exists(p) { try { fs.lstatSync(p); return true; } catch (e) { if (e.code === 'ENOENT') return false; throw e; } }
function safeChain(p) {
  let cur = path.resolve(p);
  while (true) {
    try { if (fs.lstatSync(cur).isSymbolicLink()) throw Error('Store path contains a symbolic link.'); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    const parent = path.dirname(cur); if (parent === cur) break; cur = parent;
  }
}
function linuxIdentity(pid = process.pid) {
  const boot = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
  const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
  // comm is parenthesized and can contain spaces/parentheses; fields after its final ')' start at stat field 3.
  const tail = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
  return { boot, pid, start: tail[19] }; // proc stat field 22 (starttime)
}
function sameProcess(owner) {
  try { const actual = linuxIdentity(owner.pid); return actual.boot === owner.boot && actual.start === owner.start; }
  catch (e) { if (e.code === 'ENOENT' || e.code === 'ESRCH') return false; return null; }
}
function lock(store) {
  fs.mkdirSync(store, { recursive: true, mode: 0o700 }); safeChain(store);
  const parent = path.dirname(store), lease = path.join(parent, '.linux-store-writer');
  const end = Date.now() + 10000;
  while (true) {
    let ownLease = false;
    try {
      fs.mkdirSync(lease, { mode: 0o700 });
      ownLease = true;
      const owner = process.platform === 'linux' ? linuxIdentity() : { pid: process.pid, start: `${Date.now()}-${crypto.randomBytes(8).toString('hex')}` };
      fs.writeFileSync(path.join(lease, 'owner.json'), JSON.stringify(owner), { flag: 'wx', mode: 0o600 });
      let windowsLockFd = null;
      if (process.platform === 'win32') {
        // Keep the persistent PowerShell lock file intact. Opening it fails while .NET holds FileShare.None.
        windowsLockFd = fs.openSync(path.join(store, 'store.lock'), 'a+');
      }
      return () => {
        if (windowsLockFd !== null) fs.closeSync(windowsLockFd);
        try { fs.unlinkSync(path.join(lease, 'owner.json')); fs.rmdirSync(lease); } catch (_) {}
      };
    } catch (e) {
      if (ownLease) {
        try { fs.unlinkSync(path.join(lease, 'owner.json')); fs.rmdirSync(lease); } catch (_) { /* Preserve incomplete evidence. */ }
      }
      if (e.code !== 'EEXIST' && e.code !== 'EACCES' && e.code !== 'EPERM') {
        // If lease creation succeeded but publishing owner failed, leave evidence; never remove unknown state.
        throw e;
      }
      if (e.code === 'EEXIST' && process.platform === 'linux' && exists(lease)) {
        try {
          safeChain(lease);
          const owner = JSON.parse(fs.readFileSync(path.join(lease, 'owner.json'), 'utf8'));
          if (owner.boot && Number.isInteger(owner.pid) && owner.start) {
            const live = sameProcess(owner);
            if (live === false) {
              const check = JSON.parse(fs.readFileSync(path.join(lease, 'owner.json'), 'utf8'));
              if (JSON.stringify(check) === JSON.stringify(owner)) { fs.unlinkSync(path.join(lease, 'owner.json')); fs.rmdirSync(lease); continue; }
            }
          }
        } catch (_) { /* Unknown or incomplete lease is retained as crash evidence. */ }
      }
      if (Date.now() >= end) throw Error('Encrypted store is busy or has an unresolved writer lease.');
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 80);
    }
  }
}
function writeAtomic(file, bytes) {
  if (exists(file)) safeChain(file);
  const temp = path.basename(file) === 'keyring.vault.json' ? `${file}.tmp` : `${file}.${crypto.randomBytes(8).toString('hex')}.tmp`;
  const fd = fs.openSync(temp, 'wx', 0o600);
  try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  try { fs.renameSync(temp, file); } catch (e) { try { fs.unlinkSync(temp); } catch (_) {} throw e; }
  try { const d = fs.openSync(path.dirname(file), 'r'); fs.fsyncSync(d); fs.closeSync(d); } catch (_) {}
}
function deriveVault(password, salt, iterations) { return crypto.pbkdf2Sync(password, salt, iterations, 64, 'sha256'); }
function vaultMacInput(salt, iterations, iv, cipher) { return Buffer.concat([Buffer.from(`${VAULT}\n1\nPBKDF2-HMAC-SHA256\n${iterations}\nAES-256-CBC-PKCS7\n`, 'ascii'), salt, iv, cipher]); }
function vaultEnvelope(key, password) {
  const salt = crypto.randomBytes(16), iv = crypto.randomBytes(16), keys = deriveVault(password, salt, ITERATIONS);
  const cipher = crypto.createCipheriv('aes-256-cbc', keys.subarray(0, 32), iv);
  const ciphertext = Buffer.concat([cipher.update(Buffer.from(JSON.stringify({ 'data-key': key.toString('base64') }), 'utf8')), cipher.final()]);
  const mac = crypto.createHmac('sha256', keys.subarray(32)).update(vaultMacInput(salt, ITERATIONS, iv, ciphertext)).digest();
  keys.fill(0);
  return Buffer.from(JSON.stringify({ format: VAULT, version: 1, kdf: 'PBKDF2-HMAC-SHA256', iterations: ITERATIONS, salt: salt.toString('base64'), cipher: 'AES-256-CBC-PKCS7', iv: iv.toString('base64'), ciphertext: ciphertext.toString('base64'), mac: mac.toString('base64') }), 'utf8');
}
function unwrapVault(bytes, password) {
  if (bytes.length > 50 * 1024 * 1024) throw Error('Keyring exceeds size limit.');
  let o; try { o = JSON.parse(utf8.decode(bytes)); } catch (_) { throw Error('Keyring is malformed.'); }
  if (o.format !== VAULT || o.version !== 1 || o.kdf !== 'PBKDF2-HMAC-SHA256' || o.cipher !== 'AES-256-CBC-PKCS7' || !Number.isInteger(o.iterations) || o.iterations < ITERATIONS || o.iterations > 1000000) throw Error('Unsupported keyring format.');
  let salt, iv, cipher, mac;
  try { salt=Buffer.from(o.salt,'base64');iv=Buffer.from(o.iv,'base64');cipher=Buffer.from(o.ciphertext,'base64');mac=Buffer.from(o.mac,'base64'); } catch (_) { throw Error('Keyring fields are malformed.'); }
  if(salt.length!==16||iv.length!==16||mac.length!==32||cipher.length<16||cipher.length>MAX_PLAIN+16||cipher.length%16) throw Error('Invalid keyring field lengths.');
  const keys=deriveVault(password,salt,o.iterations);
  try {
    const expected=crypto.createHmac('sha256',keys.subarray(32)).update(vaultMacInput(salt,o.iterations,iv,cipher)).digest();
    if(!secureEq(expected,mac)) throw Error('Wrong password or keyring authentication failed.');
    let plain; try { const d=crypto.createDecipheriv('aes-256-cbc',keys.subarray(0,32),iv);plain=Buffer.concat([d.update(cipher),d.final()]); } catch (_) { throw Error('Authenticated keyring could not be decrypted.'); }
    let obj; try { obj=JSON.parse(utf8.decode(plain)); } catch (_) { plain.fill(0);throw Error('Authenticated keyring payload is invalid.'); }
    plain.fill(0); const key=Buffer.from(obj['data-key']||'', 'base64'); if(key.length!==32) throw Error('Wrapped data key is invalid.'); return key;
  } finally { keys.fill(0); }
}
function subkey(key, label) { return crypto.createHmac('sha256', key).update(`CC-Switch encrypted store v1/${label}`, 'ascii').digest(); }
function archiveKey(key, label) { return crypto.createHmac('sha256', key).update(`CC-Switch encrypted archive v1/${label}`, 'ascii').digest(); }
function protect(plain,key) {
  const iv=crypto.randomBytes(16), ek=subkey(key,'AES-256-CBC'), ak=subkey(key,'HMAC-SHA256');
  try { const c=crypto.createCipheriv('aes-256-cbc',ek,iv),ciphertext=Buffer.concat([c.update(plain),c.final()]);const mac=crypto.createHmac('sha256',ak).update(Buffer.concat([iv,ciphertext])).digest();return Buffer.from(JSON.stringify({format:FORMAT,iv:iv.toString('base64'),ciphertext:ciphertext.toString('base64'),mac:mac.toString('base64')})); }
  finally { ek.fill(0);ak.fill(0); }
}
function unprotect(bytes,key) {
  if(bytes.length>MAX_CIPHER) throw Error('Encrypted generation exceeds limit.'); let o;try{o=JSON.parse(utf8.decode(bytes));}catch(_){throw Error('Encrypted generation is malformed.');}
  const iv=Buffer.from(o.iv||'','base64'),c=Buffer.from(o.ciphertext||'','base64'),mac=Buffer.from(o.mac||'','base64');if(o.format!==FORMAT||iv.length!==16||mac.length!==32||c.length<16||c.length%16)throw Error('Invalid encrypted generation.');
  const ek=subkey(key,'AES-256-CBC'),ak=subkey(key,'HMAC-SHA256');try{const expected=crypto.createHmac('sha256',ak).update(Buffer.concat([iv,c])).digest();if(!secureEq(expected,mac))throw Error('Encrypted generation authentication failed.');const d=crypto.createDecipheriv('aes-256-cbc',ek,iv);const plain=Buffer.concat([d.update(c),d.final()]);if(plain.length>MAX_PLAIN){plain.fill(0);throw Error('Decrypted generation exceeds limit.');}return plain;}finally{ek.fill(0);ak.fill(0);}
}
function archiveMacInput(kind,length,iv,ciphertext){return Buffer.concat([Buffer.from(`${ARCHIVE_FORMAT}\n${kind}\n${length}\n`,'utf8'),iv,ciphertext]);}
function assertArchiveKind(kind){if(!['claude-session-archive','linux-config-recovery'].includes(kind))throw Error('Unsupported encrypted archive kind.');}
function sealArchive(session,archiveBytes,{kind}={}){
  if(!session?.dataKey)throw Error('Encrypted store session is closed.');assertArchiveKind(kind);const plain=Buffer.from(archiveBytes);if(!plain.length||plain.length>MAX_ARCHIVE)throw Error('Archive is empty or exceeds 256 MiB.');
  const iv=crypto.randomBytes(16),ek=archiveKey(session.dataKey,'AES-256-CBC'),ak=archiveKey(session.dataKey,'HMAC-SHA256');
  try{const c=crypto.createCipheriv('aes-256-cbc',ek,iv),ciphertext=Buffer.concat([c.update(plain),c.final()]),mac=crypto.createHmac('sha256',ak).update(archiveMacInput(kind,plain.length,iv,ciphertext)).digest();return Buffer.from(JSON.stringify({format:ARCHIVE_FORMAT,kind,length:plain.length,iv:iv.toString('base64'),ciphertext:ciphertext.toString('base64'),mac:mac.toString('base64')}),'utf8');}
  finally{plain.fill(0);ek.fill(0);ak.fill(0);}
}
function openArchive(session,envelopeBytes,{kind}={}){
  if(!session?.dataKey)throw Error('Encrypted store session is closed.');assertArchiveKind(kind);const bytes=Buffer.from(envelopeBytes);if(!bytes.length||bytes.length>Math.ceil(MAX_ARCHIVE*1.4))throw Error('Encrypted archive envelope is empty or exceeds size limit.');let o;try{o=JSON.parse(utf8.decode(bytes));}catch(_){throw Error('Encrypted archive envelope is malformed.');}
  if(o.format!==ARCHIVE_FORMAT||o.kind!==kind||!Number.isSafeInteger(o.length)||o.length<1||o.length>MAX_ARCHIVE)throw Error('Encrypted archive metadata is invalid.');const iv=Buffer.from(o.iv||'','base64'),ciphertext=Buffer.from(o.ciphertext||'','base64'),mac=Buffer.from(o.mac||'','base64');if(iv.length!==16||!ciphertext.length||ciphertext.length%16||ciphertext.length>MAX_ARCHIVE+16||mac.length!==32)throw Error('Encrypted archive fields exceed limits.');
  const ek=archiveKey(session.dataKey,'AES-256-CBC'),ak=archiveKey(session.dataKey,'HMAC-SHA256');try{const expected=crypto.createHmac('sha256',ak).update(archiveMacInput(kind,o.length,iv,ciphertext)).digest();if(!secureEq(expected,mac))throw Error('Encrypted archive authentication failed.');let plain;try{const d=crypto.createDecipheriv('aes-256-cbc',ek,iv);plain=Buffer.concat([d.update(ciphertext),d.final()]);}catch(_){throw Error('Authenticated archive could not be decrypted.');}if(plain.length!==o.length||plain.length>MAX_ARCHIVE){plain.fill(0);throw Error('Encrypted archive length does not match authenticated metadata.');}return plain;}finally{ek.fill(0);ak.fill(0);}
}
function assertRelative(p) {
  if(typeof p!=='string'||!p||Buffer.byteLength(p,'utf8')>MAX_PATH||p.startsWith('/')||p.includes('\\')||p.includes(':')||/[\x00-\x1f]/.test(p))throw Error('Invalid snapshot path.');
  const parts=p.split('/');if(parts.length>MAX_DEPTH)throw Error('Snapshot path exceeds depth limit.');
  for(const x of parts){if(!x||x==='.'||x==='..'||/[<>"|?*]/.test(x)||/[. ]$/.test(x)||/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i.test(x.split('.')[0]))throw Error('Invalid snapshot path component.');}
  const low=p.toLowerCase();if(!(low.startsWith('config/cc-switch/home/.cc-switch/')||low.startsWith('harness/cc-switch/')))throw Error('Path outside supported snapshot trees.');
}
function crc32(b){let c=0xffffffff;for(const x of b){c^=x;for(let k=0;k<8;k++)c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^0xffffffff)>>>0;}
function makeZip(files) {
  const local=[],central=[];let offset=0;
  for(const [name,data] of files){const n=Buffer.from(name,'utf8'),raw=Buffer.from(data),def=zlib.deflateRawSync(raw,{level:6}),crc=crc32(raw);const l=Buffer.alloc(30);l.writeUInt32LE(0x04034b50,0);l.writeUInt16LE(20,4);l.writeUInt16LE(0x800,6);l.writeUInt16LE(8,8);l.writeUInt32LE(crc,14);l.writeUInt32LE(def.length,18);l.writeUInt32LE(raw.length,22);l.writeUInt16LE(n.length,26);local.push(l,n,def);const c=Buffer.alloc(46);c.writeUInt32LE(0x02014b50,0);c.writeUInt16LE(20,4);c.writeUInt16LE(20,6);c.writeUInt16LE(0x800,8);c.writeUInt16LE(8,10);c.writeUInt32LE(crc,16);c.writeUInt32LE(def.length,20);c.writeUInt32LE(raw.length,24);c.writeUInt16LE(n.length,28);c.writeUInt32LE(offset,42);central.push(c,n);offset+=l.length+n.length+def.length;}
  const cd=Buffer.concat(central),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50,0);end.writeUInt16LE(files.length,8);end.writeUInt16LE(files.length,10);end.writeUInt32LE(cd.length,12);end.writeUInt32LE(offset,16);return Buffer.concat([...local,cd,end]);
}
function readZip(buf) {
  if(buf.length>MAX_PLAIN||buf.length<22)throw Error('ZIP size invalid.');let eocd=-1;for(let i=buf.length-22;i>=Math.max(0,buf.length-65557);i--)if(buf.readUInt32LE(i)===0x06054b50){eocd=i;break;}if(eocd<0)throw Error('ZIP directory missing.');
  const count=buf.readUInt16LE(eocd+10),size=buf.readUInt32LE(eocd+12),start=buf.readUInt32LE(eocd+16);if(count>MAX_ENTRIES+1||start+size>eocd)throw Error('ZIP inventory exceeds limits.');const out=new Map();let at=start,total=0;
  for(let i=0;i<count;i++){if(buf.readUInt32LE(at)!==0x02014b50)throw Error('ZIP central directory invalid.');const flags=buf.readUInt16LE(at+8),method=buf.readUInt16LE(at+10),crc=buf.readUInt32LE(at+16),cs=buf.readUInt32LE(at+20),us=buf.readUInt32LE(at+24),nl=buf.readUInt16LE(at+28),xl=buf.readUInt16LE(at+30),cl=buf.readUInt16LE(at+32),lo=buf.readUInt32LE(at+42);total+=us;if(method!==8||flags&1||total>MAX_PLAIN)throw Error('Unsupported or oversized ZIP inventory.');const name=utf8.decode(buf.subarray(at+46,at+46+nl));if(out.has(name))throw Error('Duplicate ZIP entry.');if(buf.readUInt32LE(lo)!==0x04034b50)throw Error('ZIP local entry invalid.');const lnl=buf.readUInt16LE(lo+26),lxl=buf.readUInt16LE(lo+28),startData=lo+30+lnl+lxl;const raw=zlib.inflateRawSync(buf.subarray(startData,startData+cs),{maxOutputLength:MAX_PLAIN});if(raw.length!==us||crc32(raw)!==crc)throw Error('ZIP entry integrity mismatch.');out.set(name,raw);at+=46+nl+xl+cl;}
  if(out.size!==count||at!==start+size)throw Error('ZIP inventory mismatch.');return out;
}
function validateZip(buf) {
  const zip=readZip(buf),mb=zip.get('_ccenc_manifest.json');if(!mb||mb.length>1024*1024)throw Error('Snapshot manifest missing or too large.');let m;try{m=JSON.parse(utf8.decode(mb));}catch(_){throw Error('Snapshot manifest invalid.');}if(m.version!==1||!Array.isArray(m.files)||m.files.length>MAX_FILES||zip.size!==m.files.length+1)throw Error('Snapshot manifest inventory invalid.');const files=new Map(),seen=new Set();let total=0;
  for(const f of m.files){assertRelative(f.path);const k=f.path.toLowerCase();if(seen.has(k))throw Error('Duplicate or case-conflicting snapshot path.');seen.add(k);const b=zip.get(f.path);if(!b||!Number.isSafeInteger(f.length)||f.length<0||b.length!==f.length||!/^[0-9a-f]{64}$/.test(f.sha256)||hash(b)!==f.sha256)throw Error('Snapshot manifest hash/inventory mismatch.');total+=b.length;if(total>MAX_PLAIN)throw Error('Snapshot exceeds uncompressed size limit.');files.set(f.path,b);}
  for(const n of zip.keys()){if(n==='_ccenc_manifest.json')continue;assertRelative(n);if(!seen.has(n.toLowerCase()))throw Error('Unlisted ZIP entry.');}return files;
}
function status(root) {
  const s=storePath(root), key=path.join(s,'keyring.vault.json'),cur=path.join(s,'current.json'),prev=path.join(s,'previous.json'),gens=path.join(s,'generations');let state='Absent',cr=null,pr=null;
  if(exists(s)){safeChain(s);const entries=fs.readdirSync(s);if(entries.length>MAX_ENTRIES)state='Corrupt';for(const n of entries){safeChain(path.join(s,n));if(!['keyring.vault.json','keyring.vault.json.lock','current.json','previous.json','generations','migration.pending.json','store.lock'].includes(n)){if(/^(current|previous)\.json\..*\.(tmp|bak)$/.test(n)||/^keyring\.vault\.json\.(bak|tmp|restore\.tmp)$/.test(n))state='RecoveryRequired';else state='Corrupt';}}}
  if(exists(gens)){safeChain(gens);const entries=fs.readdirSync(gens);if(entries.length>MAX_ENTRIES)state='Corrupt';for(const n of entries){safeChain(path.join(gens,n));if(fs.statSync(path.join(gens,n)).isDirectory())state='Corrupt';if(!/^[0-9a-f]{32}\.bin$/.test(n)){state=/\.(tmp|bak)$/.test(n)?'RecoveryRequired':'Corrupt';}}}
  let recovery=state==='RecoveryRequired'||exists(path.join(s,'migration.pending.json'));
  if(exists(key)&&state!=='Corrupt'){state='Locked';try{const b=fs.readFileSync(key);if(!b.length||b.length>50*1024*1024)throw Error();for(const [f,set] of [[cur,'c'],[prev,'p']])if(exists(f)){const o=JSON.parse(utf8.decode(fs.readFileSync(f)));if(o.format!==FORMAT||!/^[0-9a-f]{32}$/.test(o.revision))throw Error();if(set==='c')cr=o.revision;else pr=o.revision;const gb=fs.readFileSync(path.join(gens,o.revision+'.bin'));if(!gb.length||gb.length>MAX_CIPHER)throw Error();}if(!cr&&!pr)state='Ready';if(!cr&&pr)recovery=true;}catch(_){state='Corrupt';}}
  if(!exists(key)&&(exists(cur)||exists(prev)||(exists(gens)&&fs.readdirSync(gens).length)))recovery=true;
  if(state!=='Corrupt'&&exists(gens))for(const n of fs.readdirSync(gens)){const r=n.replace(/\.bin$/,'');if(!/^[0-9a-f]{32}$/.test(r)||![cr,pr].includes(r))recovery=true;}
  if(state!=='Corrupt'&&recovery)state='RecoveryRequired';return {root:path.resolve(root),state,currentRevision:cr,previousRevision:pr};
}
function storeStatus(root){return status(root);}
function openStore(root,password,{create=false}={}) {
  if(typeof password!=='string'||password.length<1||password.length>1024)throw Error('Password must contain 1 to 1024 characters.');const s=storePath(root);safeChain(s);fs.mkdirSync(s,{recursive:true,mode:0o700});const unlock=lock(s);let key=null,keyringBytes=null;
  try{const kp=path.join(s,'keyring.vault.json');if(!exists(kp)){if(!create)throw Error('Encrypted store is absent; create must be explicitly enabled.');const before=status(root);if(before.state==='RecoveryRequired'||before.state==='Corrupt')throw Error('Encrypted store contains recovery evidence; refusing initialization.');const g=path.join(s,'generations');if(exists(path.join(s,'current.json'))||exists(path.join(s,'previous.json'))||(exists(g)&&fs.readdirSync(g).length))throw Error('Encrypted data exists without wrapped key; refusing initialization.');key=crypto.randomBytes(32);keyringBytes=vaultEnvelope(key,password);writeAtomic(kp,keyringBytes);}else{safeChain(kp);keyringBytes=fs.readFileSync(kp);key=unwrapVault(keyringBytes,password);}const st=status(root);if(st.state==='Corrupt')throw Error('Encrypted store metadata is corrupt.');return {root:path.resolve(root),dataKey:key,revision:st.currentRevision,keyringBytes,close(){if(this.dataKey)this.dataKey.fill(0);if(this.keyringBytes)this.keyringBytes.fill(0);this.dataKey=null;this.keyringBytes=null;this.revision=null;}};}catch(e){if(key)key.fill(0);if(keyringBytes)keyringBytes.fill(0);throw e;}finally{unlock();}
}
function readSnapshot(session) { if(!session?.dataKey)throw Error('Encrypted store session is closed.');const st=status(session.root);if(!st.currentRevision)return new Map();const env=fs.readFileSync(path.join(storePath(session.root),'generations',st.currentRevision+'.bin'));const plain=unprotect(env,session.dataKey);try{return validateZip(plain);}finally{plain.fill(0);} }
function captureTree(root) {
  const base = path.resolve(root), found = new Map(); safeChain(base);
  let count = 0, total = 0;
  for (const relroot of ['config/cc-switch/home/.cc-switch', 'harness/cc-switch']) {
    const start = path.join(base, ...relroot.split('/'));
    if (!exists(start)) continue;
    const stack = [start];
    while (stack.length) {
      const d = stack.pop();
      for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
        if (++count > MAX_ENTRIES) throw Error('Source exceeds directory entry limit.');
        const full = path.join(d, ent.name); safeChain(full);
        if (ent.isSymbolicLink()) throw Error('Source trees cannot contain symbolic links.');
        if (ent.isDirectory()) {
          if (/^(logs?|history|backups?|cache|sessions?|tmp|temp)$/i.test(ent.name)) continue;
          stack.push(full);
        } else if (ent.isFile()) {
          if (/(\.log(\..*)?|\.bak|\.backup|\.tmp|\.temp|\.lock|-(wal|shm|journal)|(\.wal|\.shm|\.journal))$/i.test(ent.name)) continue;
          const st = fs.statSync(full); total += st.size;
          if (total > MAX_PLAIN) throw Error('Snapshot exceeds file data limit.');
          const rel = path.relative(base, full).split(path.sep).join('/'); assertRelative(rel);
          if (found.size >= MAX_FILES) throw Error('Snapshot exceeds file count limit.');
          found.set(rel, fs.readFileSync(full));
        }
      }
    }
  }
  if (!found.size) throw Error('No files found in supported CC Switch trees.');
  return found;
}
function normalizeFiles(map){if(!(map instanceof Map)||map.size<1||map.size>MAX_FILES)throw Error('Snapshot file map is invalid.');const out=new Map();let total=0;for(const [p,v] of map){assertRelative(p);const b=Buffer.from(v);total+=b.length;if(total>MAX_PLAIN)throw Error('Snapshot exceeds file size limit.');if([...out.keys()].some(x=>x.toLowerCase()===p.toLowerCase()))throw Error('Duplicate snapshot path.');out.set(p,b);}return out;}
function makeArchive(map){const files=normalizeFiles(map),manifest={version:1,files:[...files].map(([p,b])=>({path:p,length:b.length,sha256:hash(b)}))};const mb=Buffer.from(JSON.stringify(manifest),'utf8');if(mb.length>1024*1024)throw Error('Snapshot manifest too large.');return makeZip([...files,['_ccenc_manifest.json',mb]]);}
function saveSnapshot(session,filesMap){if(!session?.dataKey)throw Error('Encrypted store session is closed.');const s=storePath(session.root),unlock=lock(s);let plain;try{const st=status(session.root);if(st.state==='Corrupt'||st.state==='RecoveryRequired')throw Error('Encrypted store requires recovery; refusing overwrite.');if(st.currentRevision!==session.revision)throw Error('Encrypted store revision changed in another session; reopen before saving.');plain=makeArchive(filesMap);if(plain.length>MAX_PLAIN)throw Error('Compressed snapshot exceeds limit.');const revision=crypto.randomBytes(16).toString('hex'),cipher=protect(plain,session.dataKey);if(cipher.length>MAX_CIPHER)throw Error('Encrypted snapshot exceeds limit.');const gens=path.join(s,'generations');fs.mkdirSync(gens,{recursive:true,mode:0o700});const gp=path.join(gens,revision+'.bin');writeAtomic(gp,cipher);const verified=unprotect(fs.readFileSync(gp),session.dataKey);try{validateZip(verified);}finally{verified.fill(0);}const old=path.join(s,'current.json'),prev=path.join(s,'previous.json');if(exists(old))writeAtomic(prev,fs.readFileSync(old));writeAtomic(old,Buffer.from(JSON.stringify({format:FORMAT,revision})));session.revision=revision;for(const n of fs.readdirSync(gens))if(/^[0-9a-f]{32}\.bin$/.test(n)&&![revision,st.currentRevision].includes(n.slice(0,-4)))fs.unlinkSync(path.join(gens,n));return revision;}finally{if(plain)plain.fill(0);unlock();}}
function restoreSnapshot(filesMap,dest){const files=normalizeFiles(filesMap),root=path.resolve(dest);safeChain(root);if(exists(root)&&fs.readdirSync(root).length)throw Error('Restore destination must be missing or empty.');if(!exists(root))fs.mkdirSync(root,{recursive:true});const created=[];try{for(const [rel,b]of files){const target=path.resolve(root,...rel.split('/'));if(!target.startsWith(root+path.sep))throw Error('Snapshot path escapes destination.');safeChain(path.dirname(target));fs.mkdirSync(path.dirname(target),{recursive:true});const fd=fs.openSync(target,'wx',0o600);try{fs.writeFileSync(fd,b);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}created.push(target);}return {files:created.length};}catch(e){for(const p of created)try{fs.unlinkSync(p);}catch(_){}throw e;}}
function providerFromSnapshot(filesMap) {
  const b=filesMap.get('harness/cc-switch/claude/settings.json');
  if(!b||b.length>1024*1024)throw Error('Fixed Claude provider settings are absent or too large.');
  let d;try{d=JSON.parse(utf8.decode(b));}catch(_){throw Error('Claude provider settings are invalid JSON.');}
  if(!d||typeof d!=='object'||!d.env||typeof d.env!=='object'||Array.isArray(d.env))throw Error('Claude provider env settings are invalid.');
  const env=d.env,name=typeof d.name==='string'&&d.name.trim()?d.name.trim():'CC Switch current Claude provider';
  const auth=typeof env.ANTHROPIC_AUTH_TOKEN==='string'?env.ANTHROPIC_AUTH_TOKEN.trim():'';
  const api=typeof env.ANTHROPIC_API_KEY==='string'?env.ANTHROPIC_API_KEY.trim():'';
  if(!!auth===!!api)throw Error('Claude provider must contain exactly one usable auth token or API key.');
  const secret=auth||api,proxyManaged=secret==='PROXY_MANAGED';
  if(/[\x00-\x1f]/.test(secret)||(!proxyManaged&&/(placeholder|your.?key|在这里填|<.*>|\$\{.*\})/i.test(secret)))throw Error('Claude provider secret is absent or unsupported.');
  if(typeof env.ANTHROPIC_BASE_URL!=='string')throw Error('Claude provider base URL is invalid.');
  let u;try{u=new URL(env.ANTHROPIC_BASE_URL.trim());}catch(_){throw Error('Claude provider base URL is invalid.');}
  if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.search||u.hash)throw Error('Claude provider base URL is invalid.');
  const hostname=u.hostname.toLowerCase().replace(/^\[|\]$/g,'');
  const loopback=hostname==='localhost'||hostname.endsWith('.localhost')||hostname==='localhost.localdomain'||hostname==='::1'||hostname.startsWith('::ffff:127.')||(net.isIP(hostname)===4&&hostname.split('.')[0]==='127');
  if(proxyManaged&&!loopback)throw Error('Proxy-managed provider must point to a loopback endpoint.');
  if(!proxyManaged&&loopback)throw Error('Direct Claude provider cannot use a loopback API endpoint.');
  const models={};
  for(const k of ['ANTHROPIC_MODEL','ANTHROPIC_SMALL_FAST_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_REASONING_MODEL']){
    const v=env[k];if(typeof v==='string'&&v.length<=256&&!/[\x00-\x1f]/.test(v)&&!/(placeholder|your.?key|在这里填|<.*>|\$\{.*\})/i.test(v))models[k]=v;
  }
  const baseUrl=proxyManaged?null:`${u.protocol}//${u.host}${u.pathname}`.replace(/\/$/,'');
  return {name,mode:proxyManaged?'proxy-managed':'direct',baseUrl,secret:proxyManaged?null:secret,authEnvironmentName:proxyManaged?null:(auth?'ANTHROPIC_AUTH_TOKEN':'ANTHROPIC_API_KEY'),models};
}
module.exports={storeStatus,openStore,readSnapshot,saveSnapshot,captureTree,restoreSnapshot,providerFromSnapshot,sealArchive,openArchive};
