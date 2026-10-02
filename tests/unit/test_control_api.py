"""Unit/component tests for target-gateway's loopback control API.

Covers the pure state helpers and the HTTP Handler end to end via an in-process
ThreadingHTTPServer on 127.0.0.1 (no Docker, no published port): engagement
start/stop, approve/revoke, status (incl. scope summary), and fail-closed
handling of bad JSON / unknown routes.
"""

import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(os.path.dirname(_HERE))

_TMP = tempfile.mkdtemp(prefix="tgw-control-unit-")
os.environ["TARGET_GATEWAY_STATE_DIR"] = os.path.join(_TMP, "state")
os.environ["TARGET_GATEWAY_SCOPE_DIR"] = os.path.join(_TMP, "scope")
for _d in ("state", "scope"):
    os.makedirs(os.path.join(_TMP, _d), exist_ok=True)

sys.path.insert(0, os.path.join(_REPO, "target-gateway"))
import control_api as ca  # noqa: E402


def _post(url, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def _get(url):
    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


class TestStateHelpers(unittest.TestCase):
    def setUp(self):
        if ca.STATE_FILE.exists():
            ca.STATE_FILE.unlink()

    def test_read_missing_is_fail_closed_default(self):
        self.assertEqual(ca._read_state(), {"engagement_id": None, "approvals": []})

    def test_write_then_read_roundtrip(self):
        ca._write_state({"engagement_id": "e1", "approvals": ["a"]})
        self.assertEqual(ca._read_state(), {"engagement_id": "e1", "approvals": ["a"]})

    def test_corrupt_state_fails_closed(self):
        ca.STATE_FILE.write_text("{bad")
        self.assertEqual(ca._read_state(), {"engagement_id": None, "approvals": []})

    def test_scope_summary_strips_comments_and_blanks(self):
        (ca.SCOPE_DIR / "s.conf").write_text(
            "# header\napi.example.com:443  # rate: 3\n\n*.foo.com\n")
        self.assertEqual(sorted(ca._scope_summary()),
                         ["*.foo.com", "api.example.com:443"])


class TestControlHandler(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), ca.Handler)
        cls.port = cls.server.server_address[1]
        cls.base = f"http://127.0.0.1:{cls.port}"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        ca._write_state({"engagement_id": None, "approvals": []})

    def test_engagement_start_resets_approvals(self):
        ca._write_state({"engagement_id": "old", "approvals": ["stale"]})
        code, body = _post(self.base + "/control/engagement/start",
                           {"engagement_id": "eng-1"})
        self.assertEqual(code, 200)
        self.assertEqual(body["engagement_id"], "eng-1")
        self.assertEqual(ca._read_state()["approvals"], [])

    def test_approve_and_revoke(self):
        _post(self.base + "/control/engagement/start", {"engagement_id": "eng-2"})
        code, body = _post(self.base + "/control/approve",
                           {"descriptor": "POST h:443/x"})
        self.assertEqual(code, 200)
        self.assertIn("POST h:443/x", ca._read_state()["approvals"])
        code, body = _post(self.base + "/control/revoke",
                           {"descriptor": "POST h:443/x"})
        self.assertEqual(code, 200)
        self.assertNotIn("POST h:443/x", ca._read_state()["approvals"])

    def test_approve_requires_descriptor(self):
        code, body = _post(self.base + "/control/approve", {"descriptor": "  "})
        self.assertEqual(code, 400)
        self.assertEqual(body["error"], "missing_descriptor")

    def test_engagement_stop_clears_everything(self):
        _post(self.base + "/control/engagement/start", {"engagement_id": "eng-3"})
        _post(self.base + "/control/approve", {"descriptor": "POST h:443/x"})
        code, _ = _post(self.base + "/control/engagement/stop", {})
        self.assertEqual(code, 200)
        state = ca._read_state()
        self.assertIsNone(state["engagement_id"])
        self.assertEqual(state["approvals"], [])

    def test_status_includes_scope(self):
        (ca.SCOPE_DIR / "s.conf").write_text("api.example.com:443\n")
        _post(self.base + "/control/engagement/start", {"engagement_id": "eng-4"})
        code, body = _get(self.base + "/status")
        self.assertEqual(code, 200)
        self.assertEqual(body["engagement_id"], "eng-4")
        self.assertIn("api.example.com:443", body["scope"])

    def test_bad_json_rejected(self):
        req = urllib.request.Request(
            self.base + "/control/approve", data=b"{not json",
            method="POST", headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=3)
            self.fail("expected HTTP 400")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 400)
            self.assertEqual(json.loads(e.read())["error"], "bad_json")

    def test_unknown_route_404(self):
        code, body = _get(self.base + "/nope")
        self.assertEqual(code, 404)


if __name__ == "__main__":
    unittest.main()
