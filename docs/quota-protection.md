# Quota / Cost Protection

## Why this exists

You have a limited monthly AI usage budget. An autonomous agent that hits an
error and blindly retries, or loops on a task it can't solve, can burn that
budget in minutes with nobody watching. This document is the full design and
state machine for the layer that prevents that. Read `docs/architecture.md`
§7 first for the high-level picture.

## What we verified vs. what we assume

* **Verified**: OpenClaw's Gateway is a Node.js process that makes outbound
  HTTPS calls to whatever model provider you configure via API key/env var
  (`docs.openclaw.ai/concepts/model-providers`). It supports being run behind
  a proxy (standard `HTTPS_PROXY`/`HTTP_PROXY` env support is how we route its
  egress; Node's built-in `undici`/`fetch` respects these when set, and the
  Docker Compose network topology in this repo means there is no other path
  out).
* **Not found / not assumed**: a documented, stable, per-task "iterations
  used" or "AI requests used" counter exposed by OpenClaw itself that an
  external process could subscribe to. If a future OpenClaw version exposes
  this (e.g. via its event/plugin API), wiring it into quota-guard as a
  second, corroborating signal would be a good follow-up, track this in
  `docs/operations.md`'s known-limitations section. Until then, request
  counting happens at the network layer, which is authoritative regardless of
  what OpenClaw's internal loop does.

## Components

### 1. quota-guard (network layer, always active)

A [mitmproxy](https://mitmproxy.org/) instance (ecosystem tool, not
reinvented) with a custom addon (`quota-guard/addons/quota_guard_addon.py`)
running as the `quota-guard` service. It is the **only** egress path for the
OpenClaw Gateway container.

**Per-provider-host circuit breaker states:**

```
CLOSED ──(N consecutive failures OR quota-exhaustion signal)──► OPEN
  ▲                                                                │
  │                                                                │
  └──(probe request succeeds)── HALF_OPEN ◄──(cooldown elapsed)────┘
                                     │
                                     └──(probe fails)──► OPEN (cooldown *= 2, capped)
```

* **CLOSED**: requests pass through normally.
* **OPEN**: requests to that host are rejected locally with a synthetic
  `503` (no network call made, this is the "stop burning quota" state).
  Reason and timestamp are persisted.
* **HALF_OPEN**: exactly one probe request is allowed through; success closes
  the circuit, failure reopens it with exponential backoff (base
  `QUOTA_GUARD_BACKOFF_BASE_SECONDS`, capped at
  `QUOTA_GUARD_BACKOFF_MAX_SECONDS`).

**Signals that open the circuit immediately (quota exhaustion, not just
transient failure, these do not wait for a failure count threshold):**

| Signal | Where checked |
| --- | --- |
| HTTP 429 with `Retry-After` header | Any allowlisted provider host |
| HTTP 401/403 (auth failure) | Treated as `AUTH_FAILED`, opens circuit, **always requires manual resume** (never auto-resumes, an expired/revoked credential doesn't fix itself) |
| HTTP 402 (payment required) | `QUOTA_EXHAUSTED`, manual resume unless a reset date is present |
| Response body matching known provider quota-exhaustion phrases (`"insufficient_quota"`, `"rate_limit_exceeded"`, `"quota_exceeded"`, `"billing_hard_limit_reached"`, `"exceeded your current quota"`) | Anthropic/OpenAI-style JSON error bodies |
| `x-ratelimit-remaining: 0` / `anthropic-ratelimit-*-remaining: 0` headers | Response headers |

**Signals that increment a failure counter (transient, 5xx, timeouts,
connection resets):** N consecutive failures (`QUOTA_GUARD_FAILURE_THRESHOLD`,
default 5) within `QUOTA_GUARD_FAILURE_WINDOW_SECONDS` (default 60) opens the
circuit as `PROVIDER_UNSTABLE`.

**Reset-time handling:** if `Retry-After` (seconds) or a provider-documented
reset timestamp header is present and parses to a value within a sane bound
(`< 31 days` from now), quota-guard schedules automatic `HALF_OPEN` at that
time. Otherwise: `PAUSED`, needs `./scripts/quota-guard.sh resume`.

### 2. pentest-task.sh (task layer, per invocation)

The wrapper you (or a cron/scheduler) use to launch one read-only analysis
engagement. One call = one task.

```bash
./scripts/pentest-task.sh \
  --spec ./engagement-spec.md \
  --target git@github.com:yourorg/yourrepo.git \
  [--branch main] [--agent main|recon|exploit|reporter] \
  [--max-runtime 2h] [--max-ai-requests 100] [--max-retries 3]
```

What it does, in order:

1. Refuses to start if `MAX_CONCURRENT_TASKS` is already reached (checks
   `state/quota-guard/tasks/*.json` for any `status == RUNNING`).
2. Refuses to start if quota-guard's global state is `QUOTA_EXHAUSTED` or
   `PAUSED`.
3. Writes `state/quota-guard/tasks/<task-id>.json`:
   ```json
   {
     "task_id": "task-20260914-1132-ab12cd",
     "status": "RUNNING",
     "repo": "git@github.com:yourorg/yourrepo.git",
     "branch": null,
     "agent_id": "main",
     "started_at": "2026-09-14T11:32:00Z",
     "iteration": 0,
     "ai_requests_used": 0,
     "retry_count": 0,
     "limits": { "max_iterations": 50, "max_ai_requests": 100, "max_retries": 3, "max_runtime_seconds": 7200 },
     "stop_reason": null
   }
   ```
4. Tells quota-guard (via its loopback-only control API,
   `POST /control/task/start`) to attribute subsequent requests to this
   `task_id` and enforce `max_ai_requests` for it specifically (concurrency
   is 1 by default, so this is unambiguous; if you raise
   `MAX_CONCURRENT_TASKS`, quota-guard requires OpenClaw to be configured with
   distinct outbound source ports per session, which the Gateway does
   naturally per-connection, see the addon source for the attribution
   logic).
5. Runs `docker compose run --rm openclaw-cli agent exec --agent <agent_id>
   --cwd <workspace-path> --json "<instruction>"`, `openclaw agent exec` is
   OpenClaw's documented headless one-shot entry point for CI/coding
   automation (embedded run, no Gateway chat session needed), under
   `timeout <max_runtime_seconds>`. `<agent_id>` defaults to `main` (see
   `docs/pentest-team.md`) and `<workspace-path>` is that agent's
   configured workspace directory.
6. Polls the task record every 5s; if `ai_requests_used >= max_ai_requests`,
   or wall-clock exceeds `max_runtime_seconds`, it sends `SIGTERM` (then
   `SIGKILL` after a grace period) to the CLI call, sets
   `status: LIMIT_REACHED`, records `stop_reason`, and exits non-zero.
7. On clean completion, `status: COMPLETED`. On CLI non-zero exit,
   `status: FAILED`. On quota-guard reporting `QUOTA_EXHAUSTED` mid-task,
   `status: QUOTA_EXHAUSTED`. `Ctrl-C` → `CANCELLED`.
8. Always writes the final task JSON and appends a one-line summary to
   `logs/agent-tasks.log`, this is your audit trail of "why did the agent
   stop."

## Configurable limits (`config/quota-guard.env`, no rebuild required)

```bash
MAX_ITERATIONS_PER_TASK=50        # soft backstop; OpenClaw's own loop governs real iteration count
MAX_AI_REQUESTS_PER_TASK=100      # hard, enforced by quota-guard counters, task is killed past this
MAX_RETRIES_PER_OPERATION=3       # informational ceiling for OpenClaw's own retry config; quota-guard's
                                   # circuit breaker is the real backstop once retries start failing fast
MAX_CONCURRENT_TASKS=1            # raise only if you also raise attribution complexity (see above)
MAX_TASK_RUNTIME=2h               # accepts Go-style durations (2h, 90m, 45s) via `timeout`-compatible parsing
QUOTA_GUARD_FAILURE_THRESHOLD=5
QUOTA_GUARD_FAILURE_WINDOW_SECONDS=60
QUOTA_GUARD_BACKOFF_BASE_SECONDS=10
QUOTA_GUARD_BACKOFF_MAX_SECONDS=3600
```

Reasonable defaults chosen to fail safe: small blast radius per task, and a
circuit breaker that trips fast (5 failures/60s) rather than slow, because the
cost of a false-positive pause (you type `resume`) is far lower than the cost
of a runaway loop.

## Visibility

```bash
./scripts/healthcheck.sh
```

```
Agent:              RUNNING
Current task:       task-20260914-1132-ab12cd
AI requests used:   17 / 100
Task iterations:    8 / 50
Task runtime:       12m / 2h
Quota state:        OK
Circuit (model provider): CLOSED
Network:            HEALTHY (0 blocked connections in last hour)
GitHub:             HEALTHY
```

`docker compose logs -f quota-guard` gives a live view of every allow/deny
decision and every circuit-breaker transition.

## Manual controls

```bash
./scripts/quota-guard.sh status
./scripts/quota-guard.sh resume        # clear PAUSED/QUOTA_EXHAUSTED after you've confirmed billing/quota is OK
./scripts/quota-guard.sh reset-circuit <host>   # force CLOSED for one provider host, use with care
./scripts/pentest-task.sh cancel <task-id>
```

---

## See also

* [Main README](../README.md): project overview and documentation map
* [Quickstart](quickstart.md): install once, then the three ways to run a pentest
* [Architecture](architecture.md): trust boundaries, decisions, the diagram
* [GPU](gpu.md): on-box inference (NVIDIA/vLLM, AMD/ROCm), model/VRAM guidance
* [Pentest team](pentest-team.md): the 4 agents, delegation, per-agent models
* [Security](security.md): host hardening, credentials, full threat model
* [Networking](networking.md): Docker topology, egress allowlist, nftables
* [Black-box live testing](blackbox-live-testing.md): scoped egress, target-gateway, approval flow
* [Caveman integration](caveman-integration.md): token-reduction skill and proxy
* [Credentials](credentials.md): the model-provider decision
* [Operations](operations.md): install/update/backup/restore/uninstall
* [Testing](testing.md): the regression suite (static, unit, live, manual)
* [Roadmap](roadmap.md): planned, not-yet-built work
