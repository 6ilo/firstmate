# Local stand-in for admin-portal POST /api/fleet/notes (transport A, bridge token).
# Implements P1: on a recorded/duplicate/refused receipt it deletes the note's words
# and keeps only {id, sent, receipt status}.
import http.server, json, os, sys
d = sys.argv[1]; TOKEN = os.environ["TOK"]
st = os.path.join(d, "portal.json")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/api/fleet/notes" or self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.send_response(401); self.end_headers(); return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        s = json.load(open(st))
        for r in body.get("receipts", []):
            for q in s["queue"]:
                if (q.get("note_id") or q.get("order_id")) == r["ref"] and "receipt" not in q:
                    q["receipt"] = r
                    if "text" in q: del q["text"]   # P1: words deleted once recorded
        json.dump(s, open(st, "w"), indent=1)
        pend = [ {k: v for k, v in q.items() if k != "receipt"} for q in s["queue"] if "receipt" not in q]
        out = json.dumps({"notes": [q for q in pend if "note_id" in q],
                          "dispatch_orders": [q for q in pend if "order_id" in q]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, fmt, *a):
        open(os.path.join(d, "access.log"), "a").write(fmt % a + "\n")
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
