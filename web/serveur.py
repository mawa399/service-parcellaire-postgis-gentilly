"""Petit serveur local : sert la carte (web/) et relaie /api/* vers pg_featureserv (port 9010).
Page et API sur la même origine -> pas de souci de CORS.
Usage : python serveur.py   puis ouvrir http://localhost:8010
"""
import http.server, urllib.request, os
API = "http://localhost:9010"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/"):
            try:
                with opener.open(API + self.path[4:], timeout=30) as r:
                    body = r.read()
                    self.send_response(r.status)
                    self.send_header("Content-Type", r.headers.get("Content-Type", "application/json"))
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers(); self.wfile.write(body)
            except urllib.error.HTTPError as e:
                self.send_error(e.code, e.reason)
            except Exception as e:
                self.send_error(502, "pg_featureserv injoignable")
        else:
            super().do_GET()
    def log_message(self, *a): pass

os.chdir(os.path.dirname(os.path.abspath(__file__)))
http.server.ThreadingHTTPServer(("127.0.0.1", 8010), Handler).serve_forever()
