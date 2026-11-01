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
const swift = path.join(root, 'SovaGrid/ProfileExportPayload.swift');
const source = fs.existsSync(swift)
  ? fs.readFileSync(swift, 'utf8').split('static let source = #"""\n')[1].split('\n"""#')[0]
  : fs.readFileSync(path.join(root, 'app/src/main/java/org/sovagrid/android/PanelFileTransferScript.kt'), 'utf8')
      .split('val source = """\n')[1].split('\n"""')[0];
function fixture({approve=true, size='70000', fail=false, cancelPending=false} = {}) {
  let click, fetches=0, active=0, peak=0;
  const messages=[];
  const context = vm.createContext({URL, Uint8Array, Number, String, Map, Error, AbortController,
    crypto:webcrypto, location:{origin:'http://127.0.0.1:8766', href:'http://127.0.0.1:8766/sovagrid/monitoring/'},
    btoa:value=>Buffer.from(value,'binary').toString('base64'), setTimeout, clearTimeout,
    document:{addEventListener(name, callback){assert.equal(name,'click'); click=callback;}},
    fetch:async (url,options)=>{
      fetches++; assert.equal(options.credentials,'same-origin'); assert.equal(options.cache,'no-store'); assert.equal(options.redirect,'error');
      if(fail) throw new Error('offline');
      let done=false;
      return {ok:true, headers:{get:name=>name==='Content-Length'?size:null},
        body:{getReader:()=>({read:async()=>done?{done:true}:(done=true,{done:false,value:new Uint8Array(70000).fill(165)}), cancel:()=>cancelPending?new Promise(()=>{}):Promise.resolve()})}};
    },
    sovagridNativeFiles:{postMessage(raw){
      const m=JSON.parse(raw); messages.push(m);
      if(m.op==='cancel') return;
      active++; peak=Math.max(peak,active);
      setImmediate(()=>{
        active--;
        const step=m.op==='chunk'?String(m.index):m.op;
        context.__sovagridFileReply(m.id,step,m.op==='start'?approve:true);
      });
    }}
  });
  vm.runInContext(source,context);
  const fire=(href='blob:http://127.0.0.1:8766/test',download='archive.bin')=>{
    let prevented=false;
    const anchor={href,download,hasAttribute:()=>true};
    click({target:{closest:()=>anchor},preventDefault(){prevented=true;}});
    return prevented;
  };
  return {fire,messages,get fetches(){return fetches;},get peak(){return peak;}};
}
async function waitDone(fixture) {
  for(let i=0;i<100;i++) {
    if(fixture.messages.some(m=>m.op==='complete'||m.op==='cancel')) return;
    await new Promise(resolve=>setTimeout(resolve,5));
  }
  assert.fail('Transfer did not finish');
}
test('authenticated blob/HTTP downloads use bounded acknowledged chunks',async()=>{
  for(const url of ['blob:http://127.0.0.1:8766/test','http://127.0.0.1:8766/api/download']) {
    const f=fixture(); assert.equal(f.fire(url),true); await waitDone(f);
    assert.deepEqual(f.messages.map(m=>m.op),['start','metadata','chunk','chunk','complete']);
    assert.equal(f.messages[2].index,0);assert.equal(f.messages[3].index,1);
    assert.equal(Buffer.from(f.messages[2].data,'base64').length,65536);
    assert.equal(f.messages.at(-1).bytes,70000); assert.equal(f.peak,1);
  }
});
test('declining native confirmation does not consume a one-use HTTP grant',async()=>{
  const f=fixture({approve:false});f.fire('http://127.0.0.1:8766/api/download');await waitDone(f);
  assert.equal(f.fetches,0);assert.deepEqual(f.messages.map(m=>m.op),['start','cancel']);
});
test('other origins and embedded credentials are never handed off',()=>{
  const f=fixture();
  for(const url of ['https://example.com/file','http://127.0.0.1:9999/file','blob:https://example.com/id','http://user:secret@127.0.0.1:8766/file'])
    assert.equal(f.fire(url),false);
  assert.equal(f.messages.length,0);assert.equal(f.fetches,0);
});
test('oversize, truncated response and network failure cancel private download',async()=>{
  for(const options of [{size:String(32*1024*1024*1024+1)},{size:'70001'},{fail:true}]) {
    const f=fixture(options);f.fire();await waitDone(f);
    assert.equal(f.messages.at(-1).op,'cancel');assert.ok(!f.messages.some(m=>m.op==='complete'));
  }
});
test('duplicate clicks cannot launch concurrent transfers',async()=>{
  const f=fixture();f.fire();f.fire();await waitDone(f);
  assert.equal(f.messages.filter(m=>m.op==='start').length,1);assert.equal(f.fetches,1);
});

test('completed transfer releases serialization even if WebKit stream cancel never resolves',async()=>{
  const f=fixture({cancelPending:true});f.fire();await waitDone(f);
  await new Promise(resolve=>setTimeout(resolve,10));
  f.fire();
  for(let i=0;i<50 && f.messages.filter(m=>m.op==='complete').length<2;i++) await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(f.messages.filter(m=>m.op==='complete').length,2);
});
