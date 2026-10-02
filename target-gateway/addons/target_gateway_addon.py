"""
target-gateway mitmproxy addon (black-box live-testing egress, Lane A).

This is a SEPARATE component from quota-guard and shares NO state or logic with
it. quota-guard is the SaaS-cost guardrail for the model provider lane (mostly
idle on an on-prem local LLM). This gateway governs TARGET traffic during a
black-box live engagement only, and is the unbypassable network boundary that
backs the platform's three hard guarantees:

  1. In-scope only: deny-by-default. A request is forwarded only if its host is
     listed in the active per-engagement scope file. Nothing above this gateway
     (the MCP server, a tool, the agent) can widen that scope.
  2. Local-only: because egress is deny-by-default to in-scope targets, any tool
     attempt to phone home (telemetry, OOB callback, third-party API) hits a host
     that is not in scope and is dropped. "Nothing leaves the sandbox except
     scoped interaction with authorized targets" is enforced here, in the network
     path, not trusted to tool code.
  3. Gentle + authorized: a per-host rate cap (spec-aware, with a safety margin,
     and a conservative default when the spec is silent) plus adaptive backoff on
     the target's own 429/503/Retry-After signals; and an approval gate that
     blocks non-idempotent (state-changing) requests until a human approves them.

Every forwarded and every denied request is appended to a local JSONL evidence
log for the report. There is no external reporting of any kind.

Design mirrors quota-guard's proven pattern (mitmproxy addon + loopback control
API + .conf file), deliberately, for codebase consistency. It does not reuse
quota-guard itself.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from mitmproxy import http, ctx

SCOPE_DIR = Path(os.environ.get("TARGET_GATEWAY_SCOPE_DIR", "/scope"))
STATE_DIR = Path(os.environ.get("TARGET_GATEWAY_STATE_DIR", "/state"))
STATE_FILE = STATE_DIR / "state.json"
EVIDENCE_DIR = Path(os.environ.get("TARGET_GATEWAY_LOG_DIR", "/logs"))

# Conservative defaults, used when the requirement spec does not state a rate.
# The launcher overrides these per engagement (see scripts/pentest-task.sh) and
# the scope file may carry a per-host "# rate:" directive derived from the spec.
RATE_DEFAULT = float(os.environ.get("TARGET_RATE_DEFAULT", "5"))          # req/s per host
MAX_CONCURRENCY = int(os.environ.get("TARGET_MAX_CONCURRENCY", "2"))
SAFETY_FACTOR = float(os.environ.get("TARGET_RATE_SAFETY_FACTOR", "0.8")) # stay under the stated limit

# Idempotent, read-only HTTP methods are Tier 0 (auto-allowed within scope+rate).
# Everything else is potentially state-changing and needs operator approval.
IDEMPOTENT_METHODS = {"GET", "HEAD", "OPTIONS"}

MAX_BACKOFF_SECONDS = 15 * 60


def _now() -> float:
    return time.time()


def _read_meta() -> tuple[Optional[str], set[str]]:
    """Read engagement id + granted approvals fresh from the control API's state
    snapshot, so an operator approval (written by control_api.py) takes effect on
    the very next request without restarting the proxy."""
    if STATE_FILE.exists():
        try:
            raw = json.loads(STATE_FILE.read_text())
            return raw.get("engagement_id"), set(raw.get("approvals", []))
        except (json.JSONDecodeError, OSError):
            pass
    return None, set()


@dataclass
class HostWindow:
    """Sliding-window rate accounting + adaptive cooldown for one target host."""

    timestamps: list = field(default_factory=list)
    cooldown_until: Optional[float] = None  # set from target 429/503/Retry-After
    rate: float = RATE_DEFAULT


class GatewayState:
    """In-memory state (approvals, rate windows, in-flight counter) plus a small
    disk snapshot of engagement id + granted approvals so an operator approval
    survives a container restart mid-engagement."""

    def __init__(self) -> None:
        self.engagement_id: Optional[str] = None
        self.approvals: set[str] = set()
        self.windows: dict[str, HostWindow] = {}
        self.in_flight = 0
        self._lock = threading.Lock()
        self.denied_count = 0
        self.forwarded_count = 0
        self._load()

    def _load(self) -> None:
        if STATE_FILE.exists():
            try:
                raw = json.loads(STATE_FILE.read_text())
                self.engagement_id = raw.get("engagement_id")
                self.approvals = set(raw.get("approvals", []))
            except (json.JSONDecodeError, OSError):
                pass

    def save(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(
                {"engagement_id": self.engagement_id, "approvals": sorted(self.approvals)},
                indent=2,
            )
        )
        os.replace(tmp, STATE_FILE)

    def window_for(self, host: str, rate: float) -> HostWindow:
        w = self.windows.get(host)
        if w is None:
            w = HostWindow(rate=rate)
            self.windows[host] = w
        else:
            w.rate = rate
        return w


def _load_scope() -> tuple[set[str], dict[str, float]]:
    """Read the active per-engagement scope. Deny-by-default: an empty or absent
    scope means nothing is in scope and every request is blocked.

    Format (one per line): host[:port] or *.suffix[:port]. A line may carry a
    trailing rate directive, e.g.  api.example.com:443   # rate: 3
    which caps that host at 3 req/s (before the safety factor).
    """
    hosts: set[str] = set()
    rates: dict[str, float] = {}
    if not SCOPE_DIR.is_dir():
        return hosts, rates
    for path in sorted(SCOPE_DIR.glob("*.conf")):
        try:
            text = path.read_text()
        except OSError:
            continue
        for line in text.splitlines():
            directive_rate = None
            if "#" in line:
                body, comment = line.split("#", 1)
                comment = comment.strip().lower()
                if comment.startswith("rate:"):
                    try:
                        directive_rate = float(comment.split(":", 1)[1].strip())
                    except ValueError:
                        directive_rate = None
            else:
                body = line
            entry = body.strip().lower()
            if not entry:
                continue
            hosts.add(entry)
            host_only = entry.split(":")[0]
            if directive_rate is not None:
                rates[host_only] = directive_rate
    return hosts, rates


def _host_in_scope(host: str, port: int, scope: set[str]) -> bool:
    host = host.lower()
    for entry in scope:
        e_host, _, e_port = entry.partition(":")
        if e_port and e_port.isdigit() and int(e_port) != port:
            continue
        if e_host.startswith("*."):
            if host == e_host[2:] or host.endswith(e_host[1:]):
                return True
        elif host == e_host:
            return True
    return False


def _descriptor(method: str, host: str, port: int, path: str) -> str:
    """Stable, human-readable approval token for a risky request. Path is reduced
    to its first segment so one approval covers an endpoint, not a single URL."""
    first_seg = "/" + path.lstrip("/").split("/", 1)[0].split("?", 1)[0]
    return f"{method} {host}:{port}{first_seg}"


class TargetGateway:
    def __init__(self) -> None:
        self.state = GatewayState()

    # ---- evidence log ------------------------------------------------------
    def _evidence(self, record: dict, eid: Optional[str] = None) -> None:
        eid = eid or self.state.engagement_id or "unscoped"
        EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
        record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = json.dumps(record, separators=(",", ":"))
        with open(EVIDENCE_DIR / f"engagement-{eid}.log", "a") as fh:
            fh.write(line + "\n")

    def _deny(self, flow: http.HTTPFlow, host: str, port: int, reason: str, code: int = 403,
              headers: Optional[dict] = None) -> None:
        self.state.denied_count += 1
        self._evidence(
            {"decision": "deny", "reason": reason, "method": flow.request.method,
             "host": host, "port": port, "path": flow.request.path},
            eid=flow.metadata.get("tg_eid"),
        )
        body = json.dumps({"blocked_by": "target-gateway", "reason": reason}).encode()
        flow.response = http.Response.make(code, body, headers or {"Content-Type": "application/json"})

    # ---- request path ------------------------------------------------------
    def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host.lower()
        port = flow.request.port
        method = flow.request.method.upper()
        scope, rate_overrides = _load_scope()
        engagement_id, approvals = _read_meta()
        flow.metadata["tg_eid"] = engagement_id

        # Guarantee 1: in-scope only (deny-by-default).
        if not scope:
            self._deny(flow, host, port, "no_active_scope")
            return
        if not _host_in_scope(host, port, scope):
            self._deny(flow, host, port, "out_of_scope")
            return

        # Guarantee 3a: approval gate for non-idempotent (state-changing) methods.
        if method not in IDEMPOTENT_METHODS:
            descriptor = _descriptor(method, host, port, flow.request.path)
            if descriptor not in approvals:
                self._deny(
                    flow, host, port, f"approval_required:{descriptor}", code=403
                )
                return

        # Guarantee 3b: adaptive cooldown from the target's own backpressure.
        effective_rate = rate_overrides.get(host, self.state.windows.get(host, HostWindow()).rate
                                             if host in self.state.windows else RATE_DEFAULT)
        effective_rate = max(effective_rate * SAFETY_FACTOR, 0.1)
        with self.state._lock:
            w = self.state.window_for(host, effective_rate)
            now = _now()
            if w.cooldown_until and now < w.cooldown_until:
                retry = int(w.cooldown_until - now) + 1
                self._deny(flow, host, port, "cooling_down", code=429,
                           headers={"Retry-After": str(retry), "Content-Type": "application/json"})
                return
            # Sliding 1s window rate cap.
            w.timestamps = [t for t in w.timestamps if now - t < 1.0]
            if len(w.timestamps) >= max(int(w.rate), 1):
                self._deny(flow, host, port, "rate_limited", code=429,
                           headers={"Retry-After": "1", "Content-Type": "application/json"})
                return
            # Concurrency cap across all in-scope hosts.
            if self.state.in_flight >= MAX_CONCURRENCY:
                self._deny(flow, host, port, "concurrency_limited", code=429,
                           headers={"Retry-After": "1", "Content-Type": "application/json"})
                return
            w.timestamps.append(now)
            self.state.in_flight += 1
            flow.metadata["tg_counted"] = True

    # ---- response path -----------------------------------------------------
    def response(self, flow: http.HTTPFlow) -> None:
        if flow.metadata.get("tg_counted"):
            with self.state._lock:
                self.state.in_flight = max(self.state.in_flight - 1, 0)
        if flow.response is None:
            return
        host = flow.request.pretty_host.lower()
        status = flow.response.status_code
        # Adaptive backoff: respect the target telling us to slow down.
        if status in (429, 503):
            retry_after = flow.response.headers.get("Retry-After", "")
            delay = MAX_BACKOFF_SECONDS
            if retry_after.isdigit():
                delay = min(int(retry_after), MAX_BACKOFF_SECONDS)
            else:
                delay = 30
            with self.state._lock:
                w = self.state.window_for(host, self.state.windows.get(host, HostWindow()).rate)
                w.cooldown_until = _now() + delay
            ctx.log.info(f"target-gateway: {host} returned {status}; backing off {delay}s")
        self.state.forwarded_count += 1
        self._evidence(
            {"decision": "forward", "method": flow.request.method, "host": host,
             "port": flow.request.port, "path": flow.request.path, "status": status,
             "resp_bytes": len(flow.response.content or b"")},
            eid=flow.metadata.get("tg_eid"),
        )

    def error(self, flow: http.HTTPFlow) -> None:
        if flow.metadata.get("tg_counted"):
            with self.state._lock:
                self.state.in_flight = max(self.state.in_flight - 1, 0)


addons = [TargetGateway()]
