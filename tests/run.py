#!/usr/bin/env python3
"""Run Lua regression tests against a local v3-beta.46 API contract fixture.
This does not start Storyteller itself or contact a user's server.
"""
import hashlib
import http.server
import io
import json
import os
import subprocess
import threading
import zipfile

archive = io.BytesIO()
with zipfile.ZipFile(archive, 'w') as epub:
    epub.writestr('mimetype', 'application/epub+zip')
    epub.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
    epub.writestr('content.opf', '<package><manifest><item id="ch" href="ch.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch"/></spine></package>')
    epub.writestr('ch.xhtml', '<html><body><p>Test book.</p></body></html>')
content = archive.getvalue()
positions = {}
changing_count = 0


def book(uuid):
    global changing_count
    if uuid == 'changing':
        changing_count += 1
    return dict(uuid=uuid, title='Wire fixture', authors=[], collections=[], series=[], status=None,
                position=None, readaloud=None, ebook=dict(uuid='wire-asset', filepath='/library/wire.epub',
                missing=False, updatedAt=str(changing_count) if uuid == 'changing' else '2026-10-01T00:00:00.000Z'))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, code, data=None, headers=None):
        raw = b'' if data is None else json.dumps(data).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path == '/api/v2/device/start':
            return self.respond(200, dict(device_code='device-code', user_code='USER-CODE',
                verification_uri='http://localhost/link', expires_in=600, interval=5))
        if self.path == '/api/v2/device/token':
            assert data['device_code'] == 'device-code'
            return self.respond(200, dict(access_token='TEST_TOKEN', token_type='bearer', expires_in=3600000))
        assert self.headers.get('Authorization') == 'Bearer TEST_TOKEN'
        assert self.path.endswith('/positions')
        old = positions.get(self.path)
        if old and (old['timestamp'] > data['timestamp'] or
                    (old['timestamp'] == data['timestamp'] and old['locator'] != data['locator'])):
            return self.respond(409, dict(message='Position already exists with a later timestamp'))
        positions[self.path] = data
        self.respond(204)

    def do_GET(self):
        assert self.headers.get('Authorization') == 'Bearer TEST_TOKEN'
        if self.path == '/api/v2/user':
            return self.respond(200, dict(id='user-1', username='fixture'))
        if self.path == '/api/v2/books':
            return self.respond(200, [book('wire-book')])
        parts = self.path.split('/')
        uuid = parts[4]
        if uuid == 'forbidden':
            return self.respond(403)
        if self.path.endswith('/positions'):
            position = positions.get(self.path)
            return self.respond(200 if position else 404, position or dict(message='No position found'))
        if '/files?format=ebook' in self.path:
            partial = self.headers.get('Range') == 'bytes=0-0'
            assert partial or self.headers.get('Range') is None
            if uuid == 'redirect':
                return self.respond(302, headers={'Location': '/must-not-follow'})
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', 'application/epub+zip')
            self.send_header('Content-Length', '1' if partial else str(len(content)))
            if partial:
                self.send_header('Content-Range', f'bytes 0-0/{len(content)}')
            self.send_header('X-Storyteller-Hash', hashlib.sha256(content).hexdigest())
            self.end_headers()
            self.wfile.write(content[:1] if partial else content[:20] if uuid == 'truncated' else content)
            return
        self.respond(200, book(uuid))


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, AUDIT_SERVER=f'http://127.0.0.1:{server.server_port}')
    result = subprocess.run(['luajit', 'tests/audit.lua'], env=env)
    server.shutdown()
    raise SystemExit(result.returncode)
