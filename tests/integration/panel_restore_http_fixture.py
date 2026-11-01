#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Jigokuraku01
# Additional author attribution terms: see ATTRIBUTION.md.
"""Synthetic >4MiB native restore picker proof; no deployment or account data."""
import hashlib
import http.server
import json
from pathlib import Path
import sys

from panel_files_http_fixture import Handler

SIZE = 8 * 1024 * 1024 + 23
PAYLOAD = (bytes(range(251)) * (SIZE // 251 + 1))[:SIZE]
PAGE = b'''<!doctype html><meta name="viewport" content="width=device-width"><title>SovaGrid</title>
<style>body{font:18px sans-serif;padding:14px}a,button{display:block;font:18px sans-serif;margin:24px 0}</style>
<p>NATIVE RESTORE FIXTURE</p><a href="/_fixture/restore-seed" download="panel-restore.bin">Download restore seed</a>
<p id="result">WAITING_NATIVE</p><button id="pick">Choose backup files</button>
<script>
const result=document.querySelector('#result');let wrapped=false,nativeReadCount=0,largestNativeRead=0;
function ready(){if(globalThis.sovagridNativeRestore){
 if(!wrapped){wrapped=true;const reply=globalThis.__sovagridRestoreReply;
  globalThis.__sovagridRestoreReply=(session,id,value)=>{
   if(value?.ok&&typeof value.data==='string'){nativeReadCount++;largestNativeRead=Math.max(largestNativeRead,atob(value.data).length)}
   reply(session,id,value)};}
 result.textContent='NATIVE_RESTORE_READY'}}
addEventListener('sovagrid-native-restore-ready',ready);ready();
pick.onclick=async()=>{try{
 const files=await sovagridNativeRestore.pickFiles();if(files.length!==1)throw Error('count');
 const f=files[0],slices=[];let textRejected=false,oversizeRejected=false,staleRejected=false;
 try{await f.text()}catch{textRejected=true}
 try{f.slice(0,4194305)}catch{oversizeRejected=true}
 for(let offset=0;offset<f.size;offset+=4194304){const end=Math.min(f.size,offset+4194304);
  const bytes=await f.slice(offset,end).arrayBuffer();
  const sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),n=>n.toString(16).padStart(2,'0')).join('');
  slices.push({offset,bytes:bytes.byteLength,sha256:sha});}
 await sovagridNativeRestore.release();try{await f.slice(0,1).arrayBuffer()}catch{staleRejected=true}
 const response=await fetch('/_fixture/restore-result',{method:'POST',body:JSON.stringify({name:f.name,size:f.size,slices,textRejected,oversizeRejected,staleRejected,nativeReadCount,largestNativeRead})});
 result.textContent=response.ok?'RESTORE_OK':'RESTORE_BAD_HASH';
}catch(e){result.textContent='RESTORE_ERROR '+e.message;
 fetch('/_fixture/browser-event',{method:'POST',body:JSON.stringify({kind:'restore-error',message:e.message})})}};
</script>'''


class RestoreHandler(Handler):
    seed_count = 0

    def do_GET(self):
        if self.path in ("/sovagrid/monitoring/", "/sovagrid/monitoring/index.html"):
            return self.reply(200, PAGE, "text/html; charset=utf-8", cookie=True)
        if self.path == "/_fixture/restore-seed":
            if "sg_native_file_fixture=yes" not in self.headers.get("Cookie", ""):
                return self.reply(403, b"Cookie missing")
            type(self).seed_count += 1
            return self.reply(200, PAYLOAD, "application/octet-stream")
        if self.path == "/_fixture/results":
            value = {"seed_downloads": self.seed_count}
            proof = self.output_directory / "native-restore-result.json"
            if proof.exists():
                value["restore"] = json.loads(proof.read_text())
            return self.reply(200, json.dumps(value).encode(), "application/json")
        return super().do_GET()

    def do_POST(self):
        if self.path != "/_fixture/restore-result":
            return super().do_POST()
        try:
            length = int(self.headers.get("Content-Length", "0"))
            assert 0 < length <= 4096
            value = json.loads(self.rfile.read(length))
            slices = []
            for offset in range(0, SIZE, 4 * 1024**2):
                block = PAYLOAD[offset:offset + 4 * 1024**2]
                slices.append({"offset": offset, "bytes": len(block),
                               "sha256": hashlib.sha256(block).hexdigest()})
            assert value == {"name": "panel-restore.bin", "size": SIZE, "slices": slices,
                             "textRejected": True, "oversizeRejected": True,
                             "staleRejected": True, "nativeReadCount": 33,
                             "largestNativeRead": 256 * 1024}
            (self.output_directory / "native-restore-result.json").write_text(json.dumps(value, indent=2) + "\n")
        except Exception:
            return self.reply(400, b"invalid restore proof")
        return self.reply(200, b"ok")


if __name__ == "__main__":
    RestoreHandler.output_directory = Path(sys.argv[1])
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), RestoreHandler).serve_forever()
