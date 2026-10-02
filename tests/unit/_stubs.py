"""Shared lightweight stubs so the pure-logic unit tests can import the
target-gateway / pentest-tools modules WITHOUT their heavy runtime deps
(mitmproxy, mcp) being installed. This keeps the unit suite runnable on any
machine / CI, not only where the service images' dependencies exist.
"""

from __future__ import annotations

import sys
import types


class CIHeaders(dict):
    """Minimal case-insensitive header map, like mitmproxy's Headers: .get() is
    case-insensitive so a tunneled 'X-HTTP-Method-Override' is found by the
    addon's lowercase lookup exactly as it would be in production."""

    def __init__(self, data=None):
        super().__init__()
        for k, v in (data or {}).items():
            self[k.lower()] = v

    def get(self, key, default=None):
        return super().get(key.lower(), default)


def install_mitmproxy_stub():
    """Register a fake `mitmproxy` package exposing just what the addon imports:
    `http` (with Response.make / HTTPFlow / Request) and `ctx` (with log.info)."""
    if "mitmproxy" in sys.modules and getattr(sys.modules["mitmproxy"], "_clawshell_stub", False):
        return

    http_mod = types.ModuleType("mitmproxy.http")

    class Response:
        def __init__(self, status_code, content, headers):
            self.status_code = status_code
            self.content = content
            self.headers = headers or {}

        @staticmethod
        def make(status_code=200, content=b"", headers=None):
            return Response(status_code, content, headers or {})

    class HTTPFlow:  # placeholder; tests use their own fake flow objects
        pass

    class Request:  # placeholder; tests use their own fake request objects
        pass

    http_mod.Response = Response
    http_mod.HTTPFlow = HTTPFlow
    http_mod.Request = Request

    ctx_mod = types.ModuleType("mitmproxy.ctx")
    ctx_mod.log = types.SimpleNamespace(
        info=lambda *a, **k: None,
        warn=lambda *a, **k: None,
        error=lambda *a, **k: None,
    )

    pkg = types.ModuleType("mitmproxy")
    pkg._clawshell_stub = True
    pkg.http = http_mod
    pkg.ctx = ctx_mod

    sys.modules["mitmproxy"] = pkg
    sys.modules["mitmproxy.http"] = http_mod
    sys.modules["mitmproxy.ctx"] = ctx_mod


def install_mcp_stub():
    """Register a fake `mcp.server.fastmcp.FastMCP` so pentest-tools server.py
    imports without the real `mcp` package. Records registered tools so the
    tests can exercise the tool functions directly."""
    if "mcp" in sys.modules and getattr(sys.modules["mcp"], "_clawshell_stub", False):
        return

    fastmcp_mod = types.ModuleType("mcp.server.fastmcp")

    class FastMCP:
        def __init__(self, name, host=None, port=None):
            self.name = name
            self.host = host
            self.port = port
            self.tools = {}
            self.ran = False

        def tool(self):
            def deco(fn):
                self.tools[fn.__name__] = fn
                return fn
            return deco

        def run(self, transport=None):
            self.ran = True

    fastmcp_mod.FastMCP = FastMCP

    server_pkg = types.ModuleType("mcp.server")
    server_pkg.fastmcp = fastmcp_mod
    root = types.ModuleType("mcp")
    root._clawshell_stub = True
    root.server = server_pkg

    sys.modules["mcp"] = root
    sys.modules["mcp.server"] = server_pkg
    sys.modules["mcp.server.fastmcp"] = fastmcp_mod
