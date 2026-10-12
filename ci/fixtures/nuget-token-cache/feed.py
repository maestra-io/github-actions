"""Fake authenticated NuGet v3 feed for scripts/test-dotnet-service-build-cache.sh.

Serves Selftest.Build and Selftest.Publish 1.0.0 (flat container only) and accepts
HTTP Basic `ci:<token>` where <token> is the CURRENT content of the token file: a
token written earlier has "expired". Usage: feed.py <port> <token file> <log file>
"""
import base64, http.server, io, json, sys, zipfile

port, token_file, log_file = int(sys.argv[1]), sys.argv[2], sys.argv[3]
IDS = ('selftest.build', 'selftest.publish')

def nupkg(pid):
    name = {'selftest.build': 'Selftest.Build', 'selftest.publish': 'Selftest.Publish'}[pid]
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(f'{name}.nuspec', f'<?xml version="1.0"?><package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd"><metadata><id>{name}</id><version>1.0.0</version><authors>selftest</authors><description>selftest</description></metadata></package>')
    return buf.getvalue()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body=b'', ctype='application/json'):
        self.send_response(code)
        if code == 401:
            self.send_header('WWW-Authenticate', 'Basic realm="selftest"')
        self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        want = 'Basic ' + base64.b64encode(f'ci:{open(token_file).read().strip()}'.encode()).decode()
        ok = self.headers.get('Authorization') == want
        with open(log_file, 'a') as f:
            f.write(f'{200 if ok else 401} {self.path}\n')
        if not ok:
            return self.send(401)
        p = self.path.split('?')[0].lower().strip('/').split('/')
        host = self.headers.get('Host')
        if p == ['v3', 'index.json']:
            return self.send(200, json.dumps({'version': '3.0.0', 'resources': [
                {'@id': f'http://{host}/flat/', '@type': 'PackageBaseAddress/3.0.0'}]}).encode())
        if len(p) == 3 and p[0] == 'flat' and p[1] in IDS and p[2] == 'index.json':
            return self.send(200, json.dumps({'versions': ['1.0.0']}).encode())
        if len(p) == 4 and p[0] == 'flat' and p[1] in IDS and p[2] == '1.0.0' and p[3] == f'{p[1]}.1.0.0.nupkg':
            return self.send(200, nupkg(p[1]), 'application/octet-stream')
        return self.send(404)

http.server.ThreadingHTTPServer(('0.0.0.0', port), H).serve_forever()
