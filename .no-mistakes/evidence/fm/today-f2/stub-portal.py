import http.server, json, os, time, uuid, urllib.parse
d = os.environ["STUB_DIR"]
def load(name):
    with open(os.path.join(d, name)) as fh:
        return json.load(fh)
def save(name, value):
    with open(os.path.join(d, name), "w") as fh:
        json.dump(value, fh)
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log(self):
        with open(os.path.join(d, "log"), "a") as fh:
            fh.write("%s %s %s\n" % (self.command, self.path, self.headers.get("Authorization")))
    def refused(self):
        with open(os.path.join(d, "mode")) as fh:
            if fh.read().strip() == "401":
                self.reply(401, {"error": "unauthorized"})
                return True
        return False
    def do_GET(self):
        self.log()
        if self.refused():
            return
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        now = int(time.time() * 1000)
        queue = load("queue.json")
        out = []
        for item in queue:
            st = item.setdefault("_state", "submitted")
            if st != "submitted" or item.get("_lease_until", 0) > now:
                continue
            item["_lease"] = str(uuid.uuid4())
            item["_lease_until"] = now + int(os.environ.get("STUB_LEASE_MS", "600000"))
            shown = {k: v for k, v in item.items() if not k.startswith("_")}
            shown["lease_id"] = item["_lease"]
            shown["lease_expires_at"] = item["_lease_until"]
            out.append(shown)
            if item.get("_withdraw_on_pull"):
                item["_state"] = "withdrawn"
        save("queue.json", queue)
        self.reply(200, {"seam_version": "1.0.0", "server_time": now, "requests": out,
                         "withdrawn": load("withdrawn.json") if "since" in q else []})
    def do_POST(self):
        self.log()
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.refused():
            return
        parts = self.path.split("/")
        queue = load("queue.json")
        for item in queue:
            if item.get("id") == parts[4] and parts[5] == "ack":
                if item.get("_ack_code"):
                    return self.reply(item["_ack_code"], {"error": "unavailable"})
                if item.get("_state") == "submitted" and item.get("_lease") == body.get("lease_id"):
                    item["_state"] = "pulled"
                    save("queue.json", queue)
                    return self.reply(200, {"id": item["id"], "state": "pulled"})
                return self.reply(409, {"error": "conflict", "state": item.get("_state")})
        self.reply(404, {"error": "not_found"})
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port"), "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
