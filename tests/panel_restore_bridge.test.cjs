// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Jigokuraku01
// Additional author attribution terms: see ATTRIBUTION.md.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const root = path.resolve(__dirname, '..');
const session = 'a'.repeat(32), origin = 'http://127.0.0.1:8766';
const swiftPath = path.join(root, 'SovaGrid/ProfileExportPayload.swift');
function swiftTemplate(file) {
  return fs.readFileSync(file, 'utf8').split('static let template = #"""\n')[1].split('\n"""#')[0];
}
function kotlinTemplate(file) {
  return fs.readFileSync(file, 'utf8').split('val template = """\n')[1].split('\n"""')[0];
}
const source = (fs.existsSync(swiftPath) ? swiftTemplate(swiftPath) : kotlinTemplate(
  path.join(root, 'app/src/main/java/org/sovagrid/android/PanelRestoreScript.kt')))
  .replaceAll('__NATIVE_SESSION__', session).replaceAll('__NATIVE_ORIGIN__', origin);
const handle = index => index.toString(16).padStart(64, '0');
const descriptor = (index=1, size=6*1024**2+31, name='images.tar') => ({handle:handle(index), name, size});
const bytes = (offset, length) => Buffer.from(Array.from({length}, (_, index) => (offset+index)%251));

function fixture(options={}) {
  const messages=[], events={}, timers=new Map(); let timerId=0, active=0, peak=0, context;
  const files=options.files || [descriptor()];
  const reply=(message,value,replySession=message.session)=>context.__sovagridRestoreReply?.(replySession,message.id,value);
  const bridge={postMessage(raw) {
    const message=JSON.parse(raw); messages.push(message);
    if (options.handle && options.handle(message,reply) === true) return;
    if (message.action === 'pick') {
      setImmediate(()=>reply(message,{ok:true,files}));
    } else if (message.action === 'release') {
      setImmediate(()=>reply(message,{ok:true}));
    } else if (message.action === 'read') {
      active++; peak=Math.max(peak,active);
      setImmediate(()=>{
        active--;
        const value=options.read ? options.read(message) :
          {ok:true,data:bytes(message.offset,message.length).toString('base64')};
        reply(message,value);
      });
    } else assert.fail('Unexpected native action');
  }};
  context=vm.createContext({Uint8Array,Number,String,Map,Set,Error,RangeError,Object,Promise,TextDecoder,
    crypto:webcrypto,location:{origin:options.origin || origin},atob,
    Event:class { constructor(type) {this.type=type;} },
    addEventListener(name, callback){events[name]=callback;},
    removeEventListener(name, callback){if(events[name]===callback)delete events[name];},
    dispatchEvent(event){(events.ready || (events.ready=[])).push(event.type);},
    setTimeout(callback,delay){const id=++timerId;timers.set(id,{callback,delay});return id;},
    clearTimeout(id){timers.delete(id);},
    ...(options.webkit ? {webkit:{messageHandlers:{sovagridRestoreChannel:bridge}}} : {sovagridRestoreChannel:bridge})
  });
  vm.runInContext(source,context);
  return {context,messages,events,timers,reply,api:context.sovagridNativeRestore,
    get peak(){return peak;},close(){events.pagehide?.();},
    fireTimeout(){const first=timers.entries().next().value;assert.ok(first);timers.delete(first[0]);first[1].callback();}};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const rejects=promise=>assert.rejects(promise, error=>error instanceof Error);

test('Apple and Android carry the exact same restore bridge',t=>{
  const apple=fs.existsSync(swiftPath) ? swiftPath : path.join(root,'../sovagrid-apple/SovaGrid/ProfileExportPayload.swift');
  const android=fs.existsSync(swiftPath) ? path.join(root,'../sovagrid-android/app/src/main/java/org/sovagrid/android/PanelRestoreScript.kt') :
    path.join(root,'app/src/main/java/org/sovagrid/android/PanelRestoreScript.kt');
  if(!fs.existsSync(apple) || !fs.existsSync(android)) {t.skip('Sibling source checkout is not present');return;}
  assert.equal(swiftTemplate(apple),kotlinTemplate(android));
});

test('a selected file larger than4MiB is read in bounded acknowledged pieces without a File dependency',async()=>{
  const f=fixture();
  try {
    assert.equal(f.context.File,undefined);
    const [file]=await f.api.pickFiles();
    assert.equal(file.name,'images.tar');assert.equal(file.size,6*1024**2+31);
    assert.equal(Object.hasOwn(file,'handle'),false);assert.equal(Object.hasOwn(file,'path'),false);
    const start=2*1024**2-7,end=start+4*1024**2;
    const actual=Buffer.from(await file.slice(start,end).arrayBuffer());
    assert.deepEqual(actual,bytes(start,end-start));
    const reads=f.messages.filter(m=>m.action==='read');
    assert.equal(reads.length,16);assert.ok(reads.every(m=>m.length<=262144&&m.session===session));
    assert.equal(reads[0].offset,start);assert.equal(reads.at(-1).offset+reads.at(-1).length,end);
    assert.equal(f.peak,1);assert.ok(f.events.ready.includes('sovagrid-native-restore-ready'));
  } finally {f.close();}
});

test('slice ranges reject overflow, negatives, fractions and requests above4MiB before native I/O',async()=>{
  const f=fixture();
  try {
    const [file]=await f.api.pickFiles();
    for(const [start,end] of [[-1,1],[0,-1],[2,1],[0,4*1024**2+1],[file.size,file.size+1],[0,Infinity],[NaN,1],[0.5,1],[true,1]])
      assert.throws(()=>file.slice(start,end),{name:'RangeError'});
    assert.equal((await file.slice(0,0).arrayBuffer()).byteLength,0);
    assert.equal(f.messages.filter(m=>m.action==='read').length,0);
  } finally {f.close();}
});

test('text is UTF8 metadata-only and capped64KiB',async()=>{
  const raw=Buffer.from('{"name":"копия"}','utf8');
  const f=fixture({files:[descriptor(1,raw.length,'receipt.json')],
    read:m=>({ok:true,data:raw.subarray(m.offset,m.offset+m.length).toString('base64')})});
  try {const [file]=await f.api.pickFiles();assert.equal(await file.text(),raw.toString('utf8'));} finally {f.close();}
  const large=fixture({files:[descriptor(1,65537)]});
  try {const [file]=await large.api.pickFiles();await assert.rejects(file.text(),{name:'RangeError'});
    assert.equal(large.messages.filter(m=>m.action==='read').length,0);} finally {large.close();}
  const invalid=fixture({files:[descriptor(1,1,'receipt.json')],read:()=>({ok:true,data:'/w=='})});
  try {const [file]=await invalid.api.pickFiles();await assert.rejects(file.text(),{name:'TypeError'});} finally {invalid.close();}
});

test('invalid selections, unsafe names and total/file limits fail closed and release handles',async()=>{
  const variants=[[],Array.from({length:6},(_,i)=>descriptor(i+1,1)),
    [descriptor(1,1),descriptor(1,1)], [descriptor(1,0)], [descriptor(1,-1)],
    [descriptor(1,true)],[descriptor(1,'2')],[descriptor(1,8*1024**3+1)],
    [descriptor(1,6*1024**3),descriptor(2,6*1024**3),descriptor(3,6*1024**3)],
    [descriptor(1,2,'../secret')],[descriptor(1,2,'a\\b')],[descriptor(1,2,'bad\nname')],
    [{...descriptor(),handle:'guessable'}]];
  for(const files of variants) {
    const f=fixture({files});
    try {await rejects(f.api.pickFiles());assert.ok(f.messages.some(m=>m.action==='release'));
      assert.equal(f.messages.filter(m=>m.action==='read').length,0);} finally {f.close();}
  }
});

test('8GiB boundaries and five selected handles require no whole-file allocation',async()=>{
  const f=fixture({files:Array.from({length:5},(_,index)=>descriptor(index+1,index===0?8*1024**3:1,'part-'+index+'.bin'))});
  try {
    const files=await f.api.pickFiles();assert.equal(files.length,5);
    const last=files[0].size-1;
    assert.deepEqual(Buffer.from(await files[0].slice(last,last+1).arrayBuffer()),bytes(last,1));
    assert.deepEqual(f.messages.filter(m=>m.action==='read').map(m=>[m.offset,m.length]),[[last,1]]);
  } finally {f.close();}
});

test('an exact64KiB metadata file is permitted as one bounded read',async()=>{
  const f=fixture({files:[descriptor(1,65536,'manifest.json')],read:m=>({ok:true,data:Buffer.alloc(m.length,97).toString('base64')})});
  try {
    const [file]=await f.api.pickFiles();assert.equal((await file.text()).length,65536);
    assert.equal(f.messages.filter(m=>m.action==='read')[0].length,65536);
  } finally {f.close();}
});

test('wrong-origin documents have no native restore API',()=>{
  for(const value of ['https://example.com','http://127.0.0.1:9999','http://localhost:8766','null']) {
    const f=fixture({origin:value});assert.equal(f.api,undefined);assert.equal(f.messages.length,0);
  }
});

test('wrong-session and old request replies cannot resolve an active selection',async()=>{
  const held=[];const f=fixture({webkit:true,handle:m=>m.action==='pick'?(held.push(m),true):false});
  try {
    let settled=false;const pending=f.api.pickFiles().then(value=>(settled=true,value));
    assert.equal(held.length,1);const request=held[0];
    f.reply(request,{ok:true,files:[descriptor()]},'b'.repeat(32));
    f.context.__sovagridRestoreReply(session,'c'.repeat(32),{ok:true,files:[descriptor()]});
    await tick();assert.equal(settled,false);
    f.reply(request,{ok:true,files:[descriptor()]});assert.equal((await pending).length,1);
  } finally {f.close();}
});

test('truncated, malformed, over-limit and failed native reads do not produce a buffer',async()=>{
  for(const value of [{ok:true,data:'%%%'},{ok:true,data:'AA=='},{ok:true,data:7},
      {ok:true,data:'A'.repeat(349529)},{ok:false,error:'File changed'}]) {
    const f=fixture({read:()=>value});
    try {const [file]=await f.api.pickFiles();await rejects(file.slice(0,20).arrayBuffer());}
    finally {f.close();}
  }
});

test('release rejects pending reads and permanently invalidates old file-like objects',async()=>{
  const held=[];const f=fixture({handle:m=>m.action==='read'?(held.push(m),true):false});
  try {
    const [file]=await f.api.pickFiles();const reading=file.slice(0,10).arrayBuffer();
    const rejected=rejects(reading);await tick();assert.equal(held.length,1);
    await f.api.release();await rejected;
    f.reply(held[0],{ok:true,data:Buffer.alloc(10).toString('base64')});
    await rejects(file.slice(0,10).arrayBuffer());
    assert.equal(f.messages.filter(m=>m.action==='read').length,1);
  } finally {f.close();}
});

test('pagehide cancels selection and releases native resources without reading data',async()=>{
  const f=fixture({handle:m=>m.action==='pick'});
  const rejected=rejects(f.api.pickFiles());f.close();await rejected;
  assert.ok(f.messages.some(m=>m.action==='release'));assert.equal(f.timers.size,0);
});

test('reads serialize across multiple selected files and simultaneous slices',async()=>{
  const f=fixture({files:[descriptor(1,1000000,'host.tar.gz'),descriptor(2,1000000,'images.tar')]});
  try {
    const [first,second]=await f.api.pickFiles();
    const results=await Promise.all([first.slice(0,600000).arrayBuffer(),second.slice(30,600030).arrayBuffer()]);
    assert.deepEqual(Buffer.from(results[0]),bytes(0,600000));assert.deepEqual(Buffer.from(results[1]),bytes(30,600000));
    assert.equal(f.peak,1);assert.deepEqual(f.messages.filter(m=>m.action==='read').map(m=>m.handle),
      [handle(1),handle(1),handle(1),handle(2),handle(2),handle(2)]);
  } finally {f.close();}
});

test('duplicate pick, cancellation and native timeout are bounded and retryable',async()=>{
  const held=[];const f=fixture({handle:m=>m.action==='pick'?(held.push(m),true):false});
  try {
    const first=f.api.pickFiles();const failed=rejects(first);
    await rejects(f.api.pickFiles());assert.equal(held.length,1);
    f.reply(held[0],{ok:false,error:'Cancelled'});await failed;
    const next=f.api.pickFiles();const timeout=rejects(next);f.fireTimeout();await timeout;
    assert.ok(f.messages.some(m=>m.action==='release'));assert.equal(f.timers.size,0);
  } finally {f.close();}
});


test('history-cache reinjection rotates native session, disposes old API and keeps duplicate injection idempotent',async()=>{
  const held=[];
  const f=fixture({handle:m=>m.action==='read'&&m.session===session?(held.push(m),true):false});
  try {
    const oldAPI=f.api;const [oldFile]=await oldAPI.pickFiles();
    vm.runInContext(source,f.context);assert.equal(f.context.sovagridNativeRestore,oldAPI);
    const oldPagehide=f.events.pagehide;
    const reading=oldFile.slice(0,10).arrayBuffer();const rejected=rejects(reading);
    await tick();assert.equal(held.length,1);
    const nextSession='b'.repeat(32);
    vm.runInContext(source.replaceAll(session,nextSession),f.context);
    const next=f.context.sovagridNativeRestore;
    assert.notEqual(next,oldAPI);assert.notEqual(f.events.pagehide,oldPagehide);
    await rejected;await rejects(oldAPI.pickFiles());await rejects(oldFile.slice(0,10).arrayBuffer());
    const [file]=await next.pickFiles();
    f.reply(held[0],{ok:true,data:Buffer.alloc(10).toString('base64')});
    assert.deepEqual(Buffer.from(await file.slice(0,10).arrayBuffer()),bytes(0,10));
    assert.equal(f.messages.filter(m=>m.action==='read').at(-1).session,nextSession);
    // A cached page can also return without changing its native session.
    f.close();vm.runInContext(source.replaceAll(session,nextSession),f.context);
    assert.notEqual(f.context.sovagridNativeRestore,next);
    assert.equal((await f.context.sovagridNativeRestore.pickFiles()).length,1);
  } finally {f.close();}
});
