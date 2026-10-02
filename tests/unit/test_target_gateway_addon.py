"""Unit tests for the target-gateway mitmproxy addon.

Focus: the pure decision logic and the request/response lifecycle that back the
platform's hard guarantees and the security fixes (full-path approval
descriptors, encoded-traversal rejection, SSRF/internal-address blocking,
effective-method gating, denied-flow evidence integrity).

No Docker, no mitmproxy install, no network: mitmproxy is stubbed and DNS is
monkeypatched. Scope/state/evidence dirs are redirected to a temp tree that is
created BEFORE the addon is imported (its path constants are read at import).
"""

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(os.path.dirname(_HERE))

sys.path.insert(0, _HERE)
import _stubs  # noqa: E402

# Redirect the addon's path constants to a throwaway tree, then stub mitmproxy,
# then import the addon so it binds to these dirs.
_TMP = tempfile.mkdtemp(prefix="tgw-unit-")
os.environ["TARGET_GATEWAY_SCOPE_DIR"] = os.path.join(_TMP, "scope")
os.environ["TARGET_GATEWAY_STATE_DIR"] = os.path.join(_TMP, "state")
os.environ["TARGET_GATEWAY_LOG_DIR"] = os.path.join(_TMP, "logs")
for _d in ("scope", "state", "logs"):
    os.makedirs(os.path.join(_TMP, _d), exist_ok=True)

_stubs.install_mitmproxy_stub()
sys.path.insert(0, os.path.join(_REPO, "target-gateway", "addons"))
import target_gateway_addon as tgw  # noqa: E402


def _addrinfo(ip):
    """Shape of one socket.getaddrinfo result row: (family, type, proto,
    canonname, sockaddr) where sockaddr == (ip, port)."""
    return [(2, 1, 6, "", (ip, 0))]


class FakeRequest:
    def __init__(self, method, host, port, path, headers=None):
        self.method = method
        self.pretty_host = host
        self.port = port
        self.path = path
        self.headers = _stubs.CIHeaders(headers or {})
        self.content = b""


class FakeResponse:
    def __init__(self, status_code, headers=None, content=b""):
        self.status_code = status_code
        self.headers = headers or {}
        self.content = content


class FakeFlow:
    def __init__(self, request):
        self.request = request
        self.metadata = {}
        self.response = None


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
class TestPathNormalization(unittest.TestCase):
    def test_collapses_dot_segments_and_slashes(self):
        self.assertEqual(tgw._normalize_path("/a//b/./c"), "/a/b/c")
        self.assertEqual(tgw._normalize_path("/feedback/%2e%2e/admin/wipe"), "/admin/wipe")
        self.assertEqual(tgw._normalize_path("/"), "/")
        self.assertEqual(tgw._normalize_path("/x?y=1"), "/x")

    def test_percent_decodes(self):
        self.assertEqual(tgw._normalize_path("/a%2Fb"), "/a/b")


class TestSuspiciousPath(unittest.TestCase):
    def test_encoded_markers_are_suspicious(self):
        for p in ("/feedback/%2e%2e/admin", "/a/%2fb", "/x/%5c", "/X/%2E%2E/y"):
            self.assertTrue(tgw._path_is_suspicious(p), p)

    def test_plain_dotdot_is_suspicious(self):
        self.assertTrue(tgw._path_is_suspicious("/a/../b"))

    def test_normal_paths_are_clean(self):
        for p in ("/", "/api/v1/users", "/login", "/a.b/c-d"):
            self.assertFalse(tgw._path_is_suspicious(p), p)


class TestEffectiveMethod(unittest.TestCase):
    def test_no_override_returns_real_method(self):
        r = FakeRequest("GET", "h", 80, "/x")
        self.assertEqual(tgw._effective_method(r), "GET")

    def test_header_override_wins_case_insensitive(self):
        r = FakeRequest("GET", "h", 80, "/x", headers={"X-HTTP-Method-Override": "delete"})
        self.assertEqual(tgw._effective_method(r), "DELETE")

    def test_alternate_override_headers(self):
        for h in ("X-Method-Override", "X-HTTP-Method"):
            r = FakeRequest("GET", "h", 80, "/x", headers={h: "PUT"})
            self.assertEqual(tgw._effective_method(r), "PUT", h)

    def test_query_param_override(self):
        r = FakeRequest("GET", "h", 80, "/x?_method=DELETE")
        self.assertEqual(tgw._effective_method(r), "DELETE")


class TestAddrInternal(unittest.TestCase):
    def test_internal_addresses(self):
        for ip in ("127.0.0.1", "10.0.0.5", "192.168.1.1", "169.254.169.254",
                   "::1", "0.0.0.0"):
            self.assertTrue(tgw._addr_is_internal(ip), ip)

    def test_public_addresses(self):
        for ip in ("8.8.8.8", "93.184.216.34", "1.1.1.1"):
            self.assertFalse(tgw._addr_is_internal(ip), ip)

    def test_non_ip_is_not_internal(self):
        self.assertFalse(tgw._addr_is_internal("example.com"))


class TestResolutionBlocked(unittest.TestCase):
    def test_ip_literal_internal_blocked(self):
        self.assertEqual(tgw._resolution_blocked("169.254.169.254"), "169.254.169.254")

    def test_ip_literal_public_allowed(self):
        self.assertIsNone(tgw._resolution_blocked("8.8.8.8"))

    def test_hostname_resolving_internal_blocked(self):
        with mock.patch.object(tgw.socket, "getaddrinfo", return_value=_addrinfo("10.1.2.3")):
            self.assertEqual(tgw._resolution_blocked("internal.example.com"), "10.1.2.3")

    def test_hostname_resolving_public_allowed(self):
        with mock.patch.object(tgw.socket, "getaddrinfo", return_value=_addrinfo("93.184.216.34")):
            self.assertIsNone(tgw._resolution_blocked("example.com"))

    def test_resolution_failure_is_not_blocked_here(self):
        import socket as _s
        with mock.patch.object(tgw.socket, "getaddrinfo", side_effect=_s.gaierror):
            self.assertIsNone(tgw._resolution_blocked("nxdomain.invalid"))


class TestDescriptor(unittest.TestCase):
    def test_uses_full_normalized_path(self):
        self.assertEqual(
            tgw._descriptor("POST", "api.example.com", 443, "/feedback/submit?x=1"),
            "POST api.example.com:443/feedback/submit",
        )


class TestHostInScope(unittest.TestCase):
    def test_exact_match(self):
        self.assertTrue(tgw._host_in_scope("api.example.com", 443, {"api.example.com"}))

    def test_out_of_scope(self):
        self.assertFalse(tgw._host_in_scope("evil.com", 443, {"api.example.com"}))

    def test_port_filter(self):
        self.assertFalse(tgw._host_in_scope("api.example.com", 443, {"api.example.com:80"}))
        self.assertTrue(tgw._host_in_scope("api.example.com", 80, {"api.example.com:80"}))

    def test_wildcard(self):
        self.assertTrue(tgw._host_in_scope("a.example.com", 443, {"*.example.com"}))
        self.assertFalse(tgw._host_in_scope("example.com.evil.com", 443, {"*.example.com"}))


# --------------------------------------------------------------------------- #
# Scope + state loaders
# --------------------------------------------------------------------------- #
class TestLoadScope(unittest.TestCase):
    def setUp(self):
        self.scope_dir = tgw.SCOPE_DIR
        for f in self.scope_dir.glob("*.conf"):
            f.unlink()

    def test_parses_hosts_and_rate_directive(self):
        (self.scope_dir / "s.conf").write_text(
            "\n".join([
                "# a comment line",
                "api.example.com:443   # rate: 3",
                "*.foo.com",
                "   ",
            ])
        )
        hosts, rates = tgw._load_scope()
        self.assertEqual(hosts, {"api.example.com:443", "*.foo.com"})
        self.assertEqual(rates, {"api.example.com": 3.0})

    def test_empty_scope_is_deny_by_default(self):
        hosts, rates = tgw._load_scope()
        self.assertEqual(hosts, set())
        self.assertEqual(rates, {})


class TestStatePersistence(unittest.TestCase):
    def setUp(self):
        self.state_file = tgw.STATE_FILE
        if self.state_file.exists():
            self.state_file.unlink()

    def test_read_meta_missing_file_is_fail_closed(self):
        eid, approvals = tgw._read_meta()
        self.assertIsNone(eid)
        self.assertEqual(approvals, set())

    def test_read_meta_roundtrip(self):
        self.state_file.write_text(json.dumps(
            {"engagement_id": "eng-1", "approvals": ["POST h:443/x"]}))
        eid, approvals = tgw._read_meta()
        self.assertEqual(eid, "eng-1")
        self.assertEqual(approvals, {"POST h:443/x"})

    def test_corrupt_state_fails_closed(self):
        self.state_file.write_text("{ not json")
        eid, approvals = tgw._read_meta()
        self.assertIsNone(eid)
        self.assertEqual(approvals, set())

    def test_gatewaystate_save_load(self):
        st = tgw.GatewayState()
        st.engagement_id = "eng-9"
        st.approvals = {"DELETE h:443/a"}
        st.save()
        reloaded = tgw.GatewayState()
        self.assertEqual(reloaded.engagement_id, "eng-9")
        self.assertEqual(reloaded.approvals, {"DELETE h:443/a"})


# --------------------------------------------------------------------------- #
# request()/response() lifecycle — the security guarantees end to end
# --------------------------------------------------------------------------- #
class TestRequestLifecycle(unittest.TestCase):
    def setUp(self):
        self.scope_dir = tgw.SCOPE_DIR
        for f in self.scope_dir.glob("*.conf"):
            f.unlink()
        if tgw.STATE_FILE.exists():
            tgw.STATE_FILE.unlink()
        # Default: in-scope host that resolves to a public address.
        self._patch = mock.patch.object(
            tgw.socket, "getaddrinfo", return_value=_addrinfo("93.184.216.34"))
        self._patch.start()
        self.gw = tgw.TargetGateway()

    def tearDown(self):
        self._patch.stop()

    def _set_scope(self, *entries):
        (self.scope_dir / "s.conf").write_text("\n".join(entries))

    def _set_state(self, engagement_id="eng", approvals=()):
        tgw.STATE_FILE.write_text(json.dumps(
            {"engagement_id": engagement_id, "approvals": list(approvals)}))

    def test_no_scope_denies(self):
        flow = FakeFlow(FakeRequest("GET", "api.example.com", 443, "/x"))
        self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertEqual(flow.response.status_code, 403)
        self.assertIn(b"no_active_scope", flow.response.content)

    def test_out_of_scope_denies(self):
        self._set_scope("api.example.com")
        flow = FakeFlow(FakeRequest("GET", "evil.com", 443, "/x"))
        self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"out_of_scope", flow.response.content)

    def test_idempotent_in_scope_is_allowed(self):
        self._set_scope("api.example.com")
        flow = FakeFlow(FakeRequest("GET", "api.example.com", 443, "/x"))
        self.gw.request(flow)
        self.assertIsNone(flow.response)
        self.assertTrue(flow.metadata.get("tg_counted"))

    def test_encoded_traversal_denied(self):
        self._set_scope("api.example.com")
        flow = FakeFlow(FakeRequest("GET", "api.example.com", 443, "/feedback/%2e%2e/admin"))
        self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"suspicious_path", flow.response.content)

    def test_internal_address_denied_even_in_scope(self):
        self._set_scope("internal.example.com")
        with mock.patch.object(tgw.socket, "getaddrinfo", return_value=_addrinfo("169.254.169.254")):
            flow = FakeFlow(FakeRequest("GET", "internal.example.com", 443, "/latest/meta-data"))
            self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"blocked_internal_address", flow.response.content)

    def test_localhost_scope_name_refused(self):
        self._set_scope("localhost")
        flow = FakeFlow(FakeRequest("GET", "localhost", 8089, "/status"))
        self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"blocked_internal_host", flow.response.content)

    def test_state_changing_requires_approval(self):
        self._set_scope("api.example.com")
        self._set_state()
        flow = FakeFlow(FakeRequest("POST", "api.example.com", 443, "/feedback/submit"))
        self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"approval_required:POST api.example.com:443/feedback/submit",
                      flow.response.content)

    def test_state_changing_allowed_when_approved(self):
        self._set_scope("api.example.com")
        self._set_state(approvals=["POST api.example.com:443/feedback/submit"])
        flow = FakeFlow(FakeRequest("POST", "api.example.com", 443, "/feedback/submit"))
        self.gw.request(flow)
        self.assertIsNone(flow.response)
        self.assertTrue(flow.metadata.get("tg_counted"))

    def test_approval_does_not_cover_sibling_endpoint(self):
        self._set_scope("api.example.com")
        self._set_state(approvals=["POST api.example.com:443/feedback"])
        flow = FakeFlow(FakeRequest("POST", "api.example.com", 443, "/feedback/../admin/wipe"))
        self.gw.request(flow)
        # dot-segment path is rejected outright (defense in depth)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"suspicious_path", flow.response.content)

    def test_method_override_cannot_bypass_gate(self):
        self._set_scope("api.example.com")
        self._set_state()
        flow = FakeFlow(FakeRequest(
            "GET", "api.example.com", 443, "/orders/42",
            headers={"X-HTTP-Method-Override": "DELETE"}))
        self.gw.request(flow)
        self.assertIsNotNone(flow.response)
        self.assertIn(b"approval_required:DELETE api.example.com:443/orders/42",
                      flow.response.content)

    def test_denied_flow_not_logged_as_forward(self):
        self._set_scope("api.example.com")
        flow = FakeFlow(FakeRequest("GET", "evil.com", 443, "/x"))
        self.gw.request(flow)  # denied -> sets tg_denied
        before = self.gw.state.forwarded_count
        self.gw.response(flow)
        self.assertEqual(self.gw.state.forwarded_count, before)

    def test_forwarded_flow_is_logged(self):
        self._set_scope("api.example.com")
        flow = FakeFlow(FakeRequest("GET", "api.example.com", 443, "/x"))
        self.gw.request(flow)
        self.assertTrue(flow.metadata.get("tg_counted"))
        flow.response = FakeResponse(200)
        before = self.gw.state.forwarded_count
        self.gw.response(flow)
        self.assertEqual(self.gw.state.forwarded_count, before + 1)

    def test_rate_limit_trips_after_burst(self):
        self._set_scope("api.example.com:443   # rate: 2")
        denied = False
        for _ in range(8):
            flow = FakeFlow(FakeRequest("GET", "api.example.com", 443, "/x"))
            self.gw.request(flow)
            if flow.response is not None and flow.response.status_code == 429:
                denied = True
                break
        self.assertTrue(denied, "expected a 429 rate_limited response within the burst")


if __name__ == "__main__":
    unittest.main()
