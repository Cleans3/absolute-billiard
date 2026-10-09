"""Share-link landing page: GET /j/<CODE> -> deep-link button + the code to paste; GET / -> APK download
(ab.apk next to this file, pushed by src/tools/publish_apk.sh). Stdlib only."""
import html
import os
import re
import shutil
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STYLE = """<style>body{{font:20px system-ui;background:#14101c;color:#eee;text-align:center;padding:12vh 1rem}}
a.b{{display:inline-block;margin:1.5rem;padding:1rem 2rem;background:#e0457b;color:#fff;border-radius:.6rem;text-decoration:none}}
code{{font-size:2.4rem;letter-spacing:.3rem}} small{{color:#aaa}}</style>"""
HEAD = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>{title}</title>""" + STYLE

PAGE = HEAD + """<h1>Absolute Billiard</h1><p>Lobby code</p><p><code>{code}</code></p>
<a class=b href="absolutebilliard://j/{code}">Open in game</a>
<p>No game? <a href="/">Install it</a>, then type the code in <b>Join</b>.</p>"""

GET = HEAD + """<h1>Absolute Billiard</h1><p>Android test build</p>
<a class=b href="/ab.apk">Download APK</a><p><small>{size} MB · built {built}</small></p>
<p><small>Open the downloaded file and allow installs from your browser when Android asks.</small></p>"""

CODE = re.compile(r"^/j/([0-9A-Za-z]{6})/?$")
APK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ab.apk")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        m = CODE.match(path)
        if m:
            self._send(PAGE.format(title="Join Absolute Billiard", code=html.escape(m.group(1).upper())).encode())
        elif path == "/" and os.path.exists(APK):
            st = os.stat(APK)
            built = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(st.st_mtime))
            self._send(GET.format(title="Get Absolute Billiard", size=round(st.st_size / 1e6), built=built).encode())
        elif path == "/ab.apk" and os.path.exists(APK):
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.android.package-archive")
            self.send_header("Content-Disposition", 'attachment; filename="absolute-billiard.apk"')
            self.send_header("Content-Length", str(os.path.getsize(APK)))
            self.end_headers()
            with open(APK, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
        else:
            self.send_error(404)

    def _send(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8892), Handler).serve_forever()
