"""
Loopback-only control API for quota-guard, run alongside the mitmproxy addon.

Exposes:
  GET  /status                      -> full state snapshot (used by healthcheck.sh)
  POST /control/task/start          -> {task_id, max_ai_requests} attribute new active task
  POST /control/task/stop           -> clear active task attribution
  POST /control/resume              -> clear PAUSED/QUOTA_EXHAUSTED for a host (manual resume)
  POST /control/reset-circuit       -> {host} force CLOSED, use with care

Bound to 127.0.0.1 only inside the quota-guard container; only reachable from
other containers via the container network, never published to the host LAN
(see compose/compose.yml — no ports: mapping for this listener).
"""

from __future__ import annotations

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE_FILE = Path(os.environ.get("QUOTA_GUARD_STATE_DIR", "/state")) / "state.json"
CONTROL_PORT = int(os.environ.get("QUOTA_GUARD_CONTROL_PORT", "8088"))


def _read_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"hosts": {}, "active_task": None}


def _write_state(state: dict) -> None:
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(tmp, STATE_FILE)


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/status":
            self._json(200, _read_state())
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid_json"})
            return

        state = _read_state()

        if self.path == "/control/task/start":
            state["active_task"] = {
                "task_id": body["task_id"],
                "max_ai_requests": body["max_ai_requests"],
                "ai_requests_used": 0,
                "started_at": time.time(),
            }
            _write_state(state)
            self._json(200, {"ok": True})
        elif self.path == "/control/task/stop":
            state["active_task"] = None
            _write_state(state)
            self._json(200, {"ok": True})
        elif self.path == "/control/resume":
            host = body.get("host")
            hosts = state.get("hosts", {})
            targets = [host] if host else list(hosts.keys())
            for h in targets:
                if h in hosts:
                    hosts[h]["state"] = "CLOSED"
                    hosts[h]["reason"] = None
                    hosts[h]["manual_resume_required"] = False
                    hosts[h]["resume_at"] = None
                    hosts[h]["failure_timestamps"] = []
            _write_state(state)
            self._json(200, {"ok": True, "resumed": targets})
        elif self.path == "/control/reset-circuit":
            host = body.get("host")
            hosts = state.get("hosts", {})
            if host in hosts:
                hosts[host] = {
                    "state": "CLOSED",
                    "reason": None,
                    "opened_at": None,
                    "resume_at": None,
                    "manual_resume_required": False,
                    "failure_timestamps": [],
                    "backoff_seconds": 10,
                    "consecutive_open_count": 0,
                }
            _write_state(state)
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not_found"})

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        pass  # keep container logs to the mitmproxy addon's own logging


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", CONTROL_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
