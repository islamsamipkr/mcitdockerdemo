"""MCIT - Tiny dependency-free web app for an Amazon ECS Fargate demo."""
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        if self.path == "/health":
            return self.reply_json(200, {"status": "ok"})
        if self.path == "/api/hello":
            return self.reply_json(200, {
                "message": "Hello from AWS ECS Fargate!",
                "hostname": socket.gethostname(),
                "time_utc": now,
            })
        if self.path == "/":
            page = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fargate Mini Demo</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b1020;color:#e2e8f0;font:16px system-ui,Arial}
.card{width:min(500px,calc(100vw - 64px));padding:32px;border:1px solid #334155;border-radius:16px;background:#151f34;box-shadow:0 12px 35px #050a14}
h1{margin-top:0;color:#5eead4}a{color:#7dd3fc}code{background:#25324b;padding:4px 8px;border-radius:6px}
</style></head><body><main class="card"><p>🐳 Python + Docker + Amazon ECR</p>
<h1>Hello from AWS Fargate!</h1><p>Your container is running on Amazon ECS Fargate.</p>
<p>Try the <a href="/api/hello">JSON API</a> or <a href="/health">health check</a>.</p>
<p>Listening on <code>8080</code> · No load balancer</p></main></body></html>"""
            data = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.reply_json(404, {"error": "Not found"})

    def reply_json(self, status, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Serving on 0.0.0.0:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
