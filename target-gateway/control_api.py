"""
Loopback-only control API for target-gateway, run alongside the mitmproxy addon.

This is the SEMANTIC/operator surface of the black-box live-testing boundary.
It is a separate component from quota-guard's control API and shares nothing with
it. It writes the small state snapshot (engagement id + granted approvals) that
the addon reads live on each request.

Exposes:
  GET  /status                 -> engagement id, scope summary, granted approvals
  POST /control/engagement/start {engagement_id} -> attribute a new engagement, reset approvals
  POST /control/engagement/stop                  -> clear engagement + approvals (scope files are
                                                    removed host-side by the launcher)
  POST /control/approve  {descriptor}            -> grant a Tier 1 (state-changing) action
  POST /control/revoke   {descriptor}            -> revoke a previously granted action

Bound to 127.0.0.1 inside the target-gateway container only; reachable from other
containers via the internal container network, never published to the host LAN
(no ports: mapping in compose/compose.yml). Consumed by scripts/pentest-task.sh
and scripts/scope.sh.
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE_FILE = Path(os.environ.get("TARGET_GATEWAY_STATE_DIR", "/state")) / "state.json"
SCOPE_DIR = Path(os.environ.get("TARGET_GATEWAY_SCOPE_DIR", "/scope"))
CONTROL_PORT = int(os.environ.get("TARGET_GATEWAY_CONTROL_PORT", "8089"))


def _read_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"engagement_id": None, "approvals": []}


def _write_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(tmp, STATE_FILE)


def _scope_summary() -> list[str]:
    entries: list[str] = []
    if SCOPE_DIR.is_dir():
        for path in sorted(SCOPE_DIR.glob("*.conf")):
            try:
                for line in path.read_text().splitlines():
                    stripped = line.split("#", 1)[0].strip()
                    if stripped:
                        entries.append(stripped)
            except OSError:
                continue
    return entries


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:  # silence default stderr logging
        pass

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/status":
            state = _read_state()
            state["scope"] = _scope_summary()
            self._json(200, state)
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "bad_json"})
            return

        state = _read_state()

        if self.path == "/control/engagement/start":
            state["engagement_id"] = body.get("engagement_id")
            state["approvals"] = []  # fresh engagement starts with nothing approved
            _write_state(state)
            self._json(200, {"ok": True, "engagement_id": state["engagement_id"]})
        elif self.path == "/control/engagement/stop":
            _write_state({"engagement_id": None, "approvals": []})
            self._json(200, {"ok": True})
        elif self.path == "/control/approve":
            descriptor = body.get("descriptor", "").strip()
            if not descriptor:
                self._json(400, {"error": "missing_descriptor"})
                return
            approvals = set(state.get("approvals", []))
            approvals.add(descriptor)
            state["approvals"] = sorted(approvals)
            _write_state(state)
            self._json(200, {"ok": True, "approved": descriptor})
        elif self.path == "/control/revoke":
            descriptor = body.get("descriptor", "").strip()
            approvals = set(state.get("approvals", []))
            approvals.discard(descriptor)
            state["approvals"] = sorted(approvals)
            _write_state(state)
            self._json(200, {"ok": True, "revoked": descriptor})
        else:
            self._json(404, {"error": "not_found"})


def main() -> None:
    SCOPE_DIR.mkdir(parents=True, exist_ok=True)
    if not STATE_FILE.exists():
        _write_state({"engagement_id": None, "approvals": []})
    server = ThreadingHTTPServer(("127.0.0.1", CONTROL_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
