#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Jigokuraku01
# Additional author attribution terms: see ATTRIBUTION.md.
"""Synthetic same-origin panel downloads and upload; no real credentials."""
import hashlib
import http.server
import json
from pathlib import Path
import sys

PAYLOAD = bytes([0, 1, 2, 0, 255, 128]) + bytes(i % 251 for i in range(200000))
BLOB_PAYLOAD = bytes(i % 251 for i in range(140003))
PAGE = b'''<!doctype html><meta name="viewport" content="width=device-width"><title>SovaGrid</title>
<style>body{font:18px sans-serif;padding:12px}a,button,label{display:block;margin:24px 0}input{font-size:18px}</style>
<p>LOCAL PANEL FIXTURE</p><a href="/_fixture/private-download" download="panel-native.bin">Download private HTTP</a>
<button id="downloadBlob">Download binary Blob</button>
<label for="upload">Choose downloaded file</label><input id="upload" type="file"><p id="result">NO_UPLOAD</p>
<script>
function browserEvent(value){fetch('/_fixture/browser-event',{method:'POST',body:JSON.stringify(value)})}
downloadBlob.onclick=()=>{try{const a=document.createElement('a');a.download='panel-blob.bin';a.href=URL.createObjectURL(new Blob([Uint8Array.from({length:140003},(_,i)=>i%251)]));browserEvent({kind:'blob-created',origin:new URL(a.href).origin,page:location.origin});document.body.append(a);a.click();a.remove()}catch(e){browserEvent({kind:'blob-error',error:e.name})}};
document.addEventListener('click',e=>{const a=e.target?.closest?.('a[download]');if(a)Promise.resolve().then(()=>browserEvent({kind:'anchor',name:a.download,origin:new URL(a.href).origin,prevented:e.defaultPrevented,trusted:e.isTrusted}))},true);
const reply=globalThis.__sovagridFileReply;
globalThis.__sovagridFileReply=(id,step,ok)=>{fetch('/_fixture/bridge-event',{method:'POST',body:JSON.stringify({step,ok})});reply(id,step,ok)};
upload.onchange=async()=>{try{const f=upload.files[0];browserEvent({kind:'upload-selected',name:f.name,bytes:f.size});const b=await f.arrayBuffer();
const sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',b)),n=>n.toString(16).padStart(2,'0')).join('');
const r=await fetch('/_fixture/upload-result',{method:'POST',body:JSON.stringify({filename:f.name,bytes:b.byteLength,sha256:sha})});
result.textContent=r.ok?'UPLOAD_OK '+b.byteLength:'UPLOAD_FAILED';}catch(e){browserEvent({kind:'upload-error',error:e.name});result.textContent='UPLOAD_FAILED'}};</script>'''

class Handler(http.server.BaseHTTPRequestHandler):
    download_count = 0
    bridge_events = []
    browser_events = []
    output_directory = Path(".")
    def reply(self, code, body, mime="text/plain", cookie=False):
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", "sg_native_file_fixture=yes; HttpOnly; SameSite=Strict; Path=/")
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, b'{"status":"ok"}', "application/json")
        if self.path in ("/sovagrid/monitoring/", "/sovagrid/monitoring/index.html"):
            return self.reply(200, PAGE, "text/html", cookie=True)
        if self.path == "/sovagrid/monitoring/manifest.webmanifest":
            return self.reply(200, b'{"name":"SovaGrid fixture"}', "application/manifest+json")
        if self.path == "/_fixture/private-download":
            if "sg_native_file_fixture=yes" not in self.headers.get("Cookie", ""):
                return self.reply(403, b"Cookie missing")
            type(self).download_count += 1
            return self.reply(200, PAYLOAD, "application/octet-stream")
        if self.path == "/_fixture/results":
            result = {"authenticated_downloads": self.download_count}
            upload = self.output_directory / "native-upload-result.json"
            if upload.exists(): result["upload"] = json.loads(upload.read_text())
            return self.reply(200, json.dumps(result).encode(), "application/json")
        self.reply(404, b"not found")
    def do_POST(self):
        if self.path == "/_fixture/browser-event":
            try:
                event = json.loads(self.rfile.read(min(2048,int(self.headers.get("Content-Length","0")))))
                type(self).browser_events.append(event)
                (self.output_directory / "native-browser-events.json").write_text(json.dumps(self.browser_events))
            except Exception: return self.reply(400,b"invalid event")
            return self.reply(200,b"ok")
        if self.path == "/_fixture/bridge-event":
            try:
                event = json.loads(self.rfile.read(min(2048,int(self.headers.get("Content-Length","0")))))
                assert set(event) == {"step", "ok"}
                type(self).bridge_events.append(event)
                (self.output_directory / "native-bridge-events.json").write_text(json.dumps(self.bridge_events))
            except Exception: return self.reply(400,b"invalid event")
            return self.reply(200,b"ok")
        if self.path != "/_fixture/upload-result" or int(self.headers.get("Content-Length", "0")) > 2048:
            return self.reply(400, b"invalid")
        try:
            result = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert result == {"filename":"panel-native.bin", "bytes":len(PAYLOAD), "sha256":hashlib.sha256(PAYLOAD).hexdigest()}
            (self.output_directory / "native-upload-result.json").write_text(json.dumps(result))
        except Exception:
            return self.reply(400, b"invalid upload")
        self.reply(200, b"ok")

if __name__ == "__main__":
    Handler.output_directory = Path(sys.argv[1])
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
