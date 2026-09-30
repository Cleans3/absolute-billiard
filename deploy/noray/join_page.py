"""Share-link landing page: GET /j/<CODE> -> deep-link button + the code to paste. Stdlib only."""
import html
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Join Absolute Billiard</title>
<style>body{{font:20px system-ui;background:#14101c;color:#eee;text-align:center;padding:12vh 1rem}}
a.b{{display:inline-block;margin:1.5rem;padding:1rem 2rem;background:#e0457b;color:#fff;border-radius:.6rem;text-decoration:none}}
code{{font-size:2.4rem;letter-spacing:.3rem}}</style>
<h1>Absolute Billiard</h1><p>Lobby code</p><p><code>{code}</code></p>
<a class=b href="absolutebilliard://j/{code}">Open in game</a>
<p>No game? Install it, then type the code in <b>Join</b>.</p>"""

CODE = re.compile(r"^/j/([0-9A-Za-z]{6})/?$")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        m = CODE.match(self.path.split("?")[0])
        if not m:
            self.send_error(404)
            return
        body = PAGE.format(code=html.escape(m.group(1).upper())).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8892), Handler).serve_forever()
