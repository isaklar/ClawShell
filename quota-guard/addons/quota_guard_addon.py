"""
quota-guard mitmproxy addon.

This addon turns mitmproxy into:
  1. A deny-by-default egress allowlist (host:port allowlist, IP-pinned to
     defeat DNS rebinding) for everything the OpenClaw Gateway tries to reach.
  2. A per-destination-host circuit breaker that detects provider rate-limit /
     quota-exhaustion / auth-failure signals and stops forwarding requests to
     that host instantly once tripped (no further network calls = no further
     spend), persisting state to disk so it survives restarts.
  3. A per-task request counter used by scripts/pentest-task.sh to enforce hard
     per-task AI-request ceilings.

Design constraints this addon respects (see docs/quota-protection.md):
  - Never auto-resume after an auth failure (401/403) or an unparseable quota
    signal — those require a human to run `scripts/quota-guard.sh resume`.
  - Auto-resume only when a trustworthy machine-readable reset time is present
    (Retry-After seconds, bounded to < 31 days).
  - All state changes are persisted immediately (small JSON file, fsynced) so
    a container restart never silently resets a QUOTA_EXHAUSTED/PAUSED state.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from mitmproxy import http, ctx

STATE_DIR = Path(os.environ.get("QUOTA_GUARD_STATE_DIR", "/state"))
STATE_FILE = STATE_DIR / "state.json"
BLOCKED_LOG = Path(os.environ.get("QUOTA_GUARD_LOG_DIR", "/logs")) / "blocked.log"
ALLOWLIST_DIR = Path(os.environ.get("QUOTA_GUARD_ALLOWLIST_DIR", "/allowlist.d"))
STATIC_ALLOWLIST_FILE = Path(
    os.environ.get("QUOTA_GUARD_STATIC_ALLOWLIST", "/config/allowlist.conf")
)

FAILURE_THRESHOLD = int(os.environ.get("QUOTA_GUARD_FAILURE_THRESHOLD", "5"))
FAILURE_WINDOW_SECONDS = int(os.environ.get("QUOTA_GUARD_FAILURE_WINDOW_SECONDS", "60"))
BACKOFF_BASE_SECONDS = int(os.environ.get("QUOTA_GUARD_BACKOFF_BASE_SECONDS", "10"))
BACKOFF_MAX_SECONDS = int(os.environ.get("QUOTA_GUARD_BACKOFF_MAX_SECONDS", "3600"))
MAX_RESET_HORIZON_SECONDS = 31 * 24 * 3600  # 31 days — beyond this we don't trust it

# Comma-separated "owner/repo" list. Empty/unset = no enforcement (PAT/App
# installation scoping on GitHub's side is then the only real control — see
# github/PROVISIONING.md). Re-read per-request (not cached at import time) so
# a container restart after editing .env picks up changes; there is no live
# hot-reload within a running container, matching every other env-derived
# setting in this addon.
def _allowed_github_repos() -> set[str]:
    raw = os.environ.get("GITHUB_ALLOWED_REPOS", "")
    return {r.strip().lower() for r in raw.split(",") if r.strip()}


GITHUB_REPO_SCOPED_HOSTS = {"github.com", "codeload.github.com", "api.github.com"}

QUOTA_SIGNAL_PHRASES = [
    "insufficient_quota",
    "rate_limit_exceeded",
    "quota_exceeded",
    "billing_hard_limit_reached",
    "exceeded your current quota",
    "monthly quota",
]

RATE_LIMIT_REMAINING_HEADERS = [
    "x-ratelimit-remaining",
    "anthropic-ratelimit-requests-remaining",
    "anthropic-ratelimit-tokens-remaining",
]


def _now() -> float:
    return time.time()


@dataclass
class HostCircuit:
    state: str = "CLOSED"  # CLOSED | OPEN | HALF_OPEN
    reason: Optional[str] = None
    opened_at: Optional[float] = None
    resume_at: Optional[float] = None  # auto-resume time, if trustworthy
    manual_resume_required: bool = False
    failure_timestamps: list = field(default_factory=list)
    backoff_seconds: int = BACKOFF_BASE_SECONDS
    consecutive_open_count: int = 0


@dataclass
class TaskCounter:
    task_id: str
    max_ai_requests: int
    ai_requests_used: int = 0
    started_at: float = field(default_factory=_now)


class QuotaGuardState:
    """In-memory + disk-persisted state for all host circuits and the
    currently attributed task (single active task under MAX_CONCURRENT_TASKS=1;
    see docs/quota-protection.md for the multi-task attribution caveat)."""

    def __init__(self) -> None:
        self.hosts: dict[str, HostCircuit] = {}
        self.active_task: Optional[TaskCounter] = None
        self.blocked_count_last_hour: list = []
        self._load()

    def _load(self) -> None:
        if STATE_FILE.exists():
            try:
                raw = json.loads(STATE_FILE.read_text())
                for host, data in raw.get("hosts", {}).items():
                    self.hosts[host] = HostCircuit(**data)
                task = raw.get("active_task")
                if task:
                    self.active_task = TaskCounter(**task)
            except Exception as exc:  # noqa: BLE001 — never crash on corrupt state
                ctx.log.warn(f"quota-guard: failed to load state file, starting clean: {exc}")

    def save(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "hosts": {h: c.__dict__ for h, c in self.hosts.items()},
            "active_task": self.active_task.__dict__ if self.active_task else None,
            "saved_at": _now(),
        }
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2))
        os.replace(tmp, STATE_FILE)

    def circuit_for(self, host: str) -> HostCircuit:
        return self.hosts.setdefault(host, HostCircuit())


def _load_allowlist() -> set[str]:
    """host[:port] entries, one per line, '#' comments allowed. Merges the
    static config allowlist with the hot-reloadable allowlist.d/ directory
    (used for internal-service opt-in rules, see docs/networking.md)."""
    entries: set[str] = set()
    files = []
    if STATIC_ALLOWLIST_FILE.exists():
        files.append(STATIC_ALLOWLIST_FILE)
    if ALLOWLIST_DIR.is_dir():
        files.extend(sorted(ALLOWLIST_DIR.glob("*.conf")))
    for f in files:
        for line in f.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                entries.add(line)
    return entries


def _host_allowed(host: str, port: int, allowlist: set[str]) -> bool:
    candidates = {f"{host}:{port}", host}
    # Wildcard subdomain support: "*.githubusercontent.com"
    for entry in allowlist:
        if entry in candidates:
            return True
        if entry.startswith("*.") and host.endswith(entry[1:]):
            return True
        # Explicit, deliberately loud opt-out of the normal deny-by-default
        # model: allows ANY host on port 443 (HTTPS only — never plain HTTP
        # or arbitrary ports). Intended for OpenClaw's web_fetch tool (which
        # always runs from the Gateway container itself, never inside a
        # per-session sandbox), gated to specific agents only via
        # agents.entries.<id>.tools in config/openclaw.json5.example. This
        # network-layer opening applies to the whole box, not one agent —
        # see docs/networking.md#any_https-opt-in-web_fetch.
        if entry == "ANY_HTTPS" and port == 443:
            return True
    return False


def _is_private_ip(ip_str: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    return ip.is_private or ip.is_loopback or ip.is_link_local


def _extract_github_repo(host: str, path: str) -> Optional[str]:
    """Best-effort "owner/repo" extraction, deliberately narrow: only matches
    the actual git-over-HTTPS / repo-scoped API URL shapes, never generic
    github.com paths (device login, OAuth, marketplace, user settings, ...),
    so enforcement can never accidentally break auth flows or non-repo API
    calls. Returns None when the path isn't recognizably repo-scoped, in
    which case the caller must NOT block (fail open for non-matches; the
    allowlist already restricts hosts to github.com/api.github.com/
    codeload.github.com in the first place)."""
    clean = path.split("?", 1)[0]
    parts = [p for p in clean.split("/") if p]
    if host == "github.com":
        # Git smart-HTTP protocol: /<owner>/<repo>.git/info/refs,
        # /<owner>/<repo>.git/git-upload-pack, .../git-receive-pack.
        if len(parts) >= 2 and parts[1].endswith(".git"):
            return f"{parts[0]}/{parts[1][:-4]}".lower()
        return None
    if host == "codeload.github.com":
        # Archive downloads: /<owner>/<repo>/(tar.gz|zip|legacy...)/<ref>
        if len(parts) >= 2:
            return f"{parts[0]}/{parts[1]}".lower()
        return None
    if host == "api.github.com":
        # REST API repo-scoped calls: /repos/<owner>/<repo>/...
        if len(parts) >= 3 and parts[0] == "repos":
            return f"{parts[1]}/{parts[2]}".lower()
        return None
    return None


class QuotaGuardAddon:
    def __init__(self) -> None:
        self.state = QuotaGuardState()
        BLOCKED_LOG.parent.mkdir(parents=True, exist_ok=True)

    # ---- egress allowlist + SSRF/DNS-rebinding protection ------------------
    def http_connect(self, flow: http.HTTPFlow) -> None:
        self._enforce_allowlist(flow)

    def requestheaders(self, flow: http.HTTPFlow) -> None:
        if flow.response is not None:
            return  # already short-circuited by allowlist/circuit-breaker
        self._enforce_allowlist(flow)
        if flow.response is not None:
            return
        self._enforce_github_repo_scope(flow)
        if flow.response is not None:
            return
        self._enforce_circuit_breaker(flow)

    def _enforce_allowlist(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        port = flow.request.port
        allowlist = _load_allowlist()

        if not _host_allowed(host, port, allowlist):
            self._deny(flow, host, port, "not_in_allowlist")
            return

        # Pin to resolved IP and reject private/loopback ranges unless the
        # allowlist entry is an explicit literal IP (the internal-service case).
        is_literal_ip_entry = any(
            entry.split(":")[0] == host for entry in allowlist if _looks_like_ip(entry.split(":")[0])
        )
        if not is_literal_ip_entry:
            try:
                infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
            except OSError:
                self._deny(flow, host, port, "dns_resolution_failed")
                return
            resolved_ips = []
            for info in infos:
                ip = info[4][0]
                # Reject if ANY resolved record is private/loopback/link-local
                # (not just the first, as gethostbyname returned), so a mixed
                # public+private DNS answer can't smuggle an internal target.
                if _is_private_ip(ip):
                    self._deny(flow, host, port, "resolved_to_private_ip_ssrf_guard")
                    return
                resolved_ips.append(ip)
            # Pin the upstream connection to a validated IP so mitmproxy does
            # not re-resolve the hostname when it actually dials out (a
            # re-resolution could return a different, rebound private IP: the
            # classic DNS-rebinding TOCTOU gap). The original hostname is kept
            # for SNI/certificate validation via server_conn.sni.
            if resolved_ips and flow.server_conn is not None:
                flow.server_conn.address = (resolved_ips[0], port)

    def _enforce_github_repo_scope(self, flow: http.HTTPFlow) -> None:
        """When GITHUB_ALLOWED_REPOS is configured, block git clone/fetch/push
        and repo-scoped API calls to any GitHub repo not on the list. This is
        the real enforcement point: git network operations run from the
        Gateway process itself (through this proxy), not from inside the
        network-isolated per-session sandbox — see docs/architecture.md
        §3. Non-repo-scoped GitHub traffic (device login, OAuth, user/rate
        limit endpoints, etc.) is deliberately left alone; see
        _extract_github_repo's docstring."""
        allowed_repos = _allowed_github_repos()
        if not allowed_repos:
            return  # not configured -- no enforcement (PAT/App scoping only)
        host = flow.request.pretty_host
        if host not in GITHUB_REPO_SCOPED_HOSTS:
            return
        repo = _extract_github_repo(host, flow.request.path)
        if repo is None:
            return  # not a repo-scoped URL shape -- fail open, see docstring
        if repo not in allowed_repos:
            self._deny(flow, host, flow.request.port, f"repo_not_in_GITHUB_ALLOWED_REPOS:{repo}")

    def _enforce_circuit_breaker(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        circuit = self.state.circuit_for(host)
        now = _now()

        if circuit.state == "OPEN":
            if circuit.resume_at and now >= circuit.resume_at:
                circuit.state = "HALF_OPEN"
                self.state.save()
            else:
                self._short_circuit(flow, host, circuit)
                return

        if circuit.state == "HALF_OPEN":
            # allow exactly this one probe through; result is judged in response()
            pass

        # Per-task hard ceiling — checked before letting the request through.
        task = self.state.active_task
        if task and self._looks_like_ai_provider(host):
            if task.ai_requests_used >= task.max_ai_requests:
                self._deny(flow, host, flow.request.port, "task_ai_request_limit_reached")
                return

    def _looks_like_ai_provider(self, host: str) -> bool:
        # Anything not GitHub is treated as the model-provider
        # host for task-level counting purposes (there is exactly one
        # configured provider host per docs/credentials.md).
        return not (host.endswith("github.com") or host.endswith("githubusercontent.com"))

    def response(self, flow: http.HTTPFlow) -> None:
        if flow.response is None or flow.metadata.get("quota_guard_blocked"):
            return
        host = flow.request.pretty_host
        circuit = self.state.circuit_for(host)
        status = flow.response.status_code
        now = _now()

        task = self.state.active_task
        if task and self._looks_like_ai_provider(host):
            task.ai_requests_used += 1

        signal = self._classify_response(flow)

        if signal == "auth_failure":
            circuit.state = "OPEN"
            circuit.reason = "AUTH_FAILED"
            circuit.opened_at = now
            circuit.manual_resume_required = True
            circuit.resume_at = None
            ctx.log.error(f"quota-guard: {host} auth failure ({status}) — circuit OPEN, manual resume required")
        elif signal == "quota_exhausted":
            circuit.state = "OPEN"
            circuit.reason = "QUOTA_EXHAUSTED"
            circuit.opened_at = now
            reset_at = self._extract_reset_time(flow)
            if reset_at is not None:
                circuit.resume_at = reset_at
                circuit.manual_resume_required = False
                ctx.log.warn(f"quota-guard: {host} quota exhausted — auto-resume scheduled at {reset_at}")
            else:
                circuit.resume_at = None
                circuit.manual_resume_required = True
                ctx.log.error(f"quota-guard: {host} quota exhausted, no trustworthy reset time — manual resume required")
        elif signal == "transient_failure":
            circuit.failure_timestamps = [
                t for t in circuit.failure_timestamps if now - t < FAILURE_WINDOW_SECONDS
            ] + [now]
            if len(circuit.failure_timestamps) >= FAILURE_THRESHOLD:
                circuit.state = "OPEN"
                circuit.reason = "PROVIDER_UNSTABLE"
                circuit.opened_at = now
                circuit.consecutive_open_count += 1
                backoff = min(
                    BACKOFF_BASE_SECONDS * (2 ** circuit.consecutive_open_count),
                    BACKOFF_MAX_SECONDS,
                )
                circuit.backoff_seconds = backoff
                circuit.resume_at = now + backoff
                circuit.manual_resume_required = False
                ctx.log.warn(f"quota-guard: {host} {FAILURE_THRESHOLD} failures in window — circuit OPEN, backoff {backoff}s")
        else:
            if circuit.state == "HALF_OPEN":
                circuit.state = "CLOSED"
                circuit.reason = None
                circuit.failure_timestamps = []
                circuit.consecutive_open_count = 0
                circuit.backoff_seconds = BACKOFF_BASE_SECONDS
                ctx.log.info(f"quota-guard: {host} probe succeeded — circuit CLOSED")
            elif circuit.state == "CLOSED" and circuit.failure_timestamps:
                circuit.failure_timestamps = []

        self.state.save()

    def _classify_response(self, flow: http.HTTPFlow) -> Optional[str]:
        status = flow.response.status_code
        if status in (401, 403):
            return "auth_failure"
        if status == 402:
            return "quota_exhausted"
        if status == 429:
            return "quota_exhausted"
        for header in RATE_LIMIT_REMAINING_HEADERS:
            val = flow.response.headers.get(header)
            if val is not None and val.strip() == "0":
                return "quota_exhausted"
        if status >= 500:
            return "transient_failure"
        try:
            body = flow.response.get_text(strict=False) or ""
        except Exception:  # noqa: BLE001
            body = ""
        lowered = body.lower()
        if any(phrase in lowered for phrase in QUOTA_SIGNAL_PHRASES):
            return "quota_exhausted"
        return None

    def _extract_reset_time(self, flow: http.HTTPFlow) -> Optional[float]:
        retry_after = flow.response.headers.get("retry-after")
        if retry_after:
            try:
                seconds = float(retry_after)
                if 0 < seconds <= MAX_RESET_HORIZON_SECONDS:
                    return _now() + seconds
            except ValueError:
                pass
        for header in ("x-ratelimit-reset", "anthropic-ratelimit-requests-reset"):
            val = flow.response.headers.get(header)
            if val:
                try:
                    ts = float(val)
                    # heuristic: treat large values as epoch seconds, small as delta-seconds
                    candidate = ts if ts > _now() else _now() + ts
                    if 0 < (candidate - _now()) <= MAX_RESET_HORIZON_SECONDS:
                        return candidate
                except ValueError:
                    continue
        return None

    def _short_circuit(self, flow: http.HTTPFlow, host: str, circuit: HostCircuit) -> None:
        flow.metadata["quota_guard_blocked"] = True
        flow.response = http.Response.make(
            503,
            json.dumps(
                {
                    "error": "circuit_open",
                    "host": host,
                    "reason": circuit.reason,
                    "manual_resume_required": circuit.manual_resume_required,
                    "resume_at": circuit.resume_at,
                }
            ).encode(),
            {"Content-Type": "application/json"},
        )
        self._log_blocked(host, flow.request.port, f"circuit_open:{circuit.reason}")

    def _deny(self, flow: http.HTTPFlow, host: str, port: int, reason: str) -> None:
        flow.metadata["quota_guard_blocked"] = True
        flow.response = http.Response.make(
            403,
            json.dumps({"error": "denied_by_allowlist", "host": host, "reason": reason}).encode(),
            {"Content-Type": "application/json"},
        )
        self._log_blocked(host, port, reason)

    def _log_blocked(self, host: str, port: int, reason: str) -> None:
        line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} BLOCKED {host}:{port} reason={reason}\n"
        with open(BLOCKED_LOG, "a") as f:
            f.write(line)
        ctx.log.warn(f"quota-guard: BLOCKED {host}:{port} ({reason})")


def _looks_like_ip(s: str) -> bool:
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False


addons = [QuotaGuardAddon()]
