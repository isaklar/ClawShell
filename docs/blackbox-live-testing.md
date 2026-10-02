# Black-box live testing

ClawShell is read-only by default: in white-box mode, and in black-box mode
without live testing armed, the agents have no network route to any target and
only read code and reason about it. Some black-box engagements, though, need
real **dynamic** testing of a running target (often the spec gives only URLs and
no source). This document describes the opt-in capability that allows that,
safely.

The design goal is simple: let the team actively test, but make it structurally
impossible to test anything the spec did not authorize, to be aggressive or
destructive, to report anything outside the box, or to exceed a safe request
rate. these are network facts, not promises in a prompt.

## When it is active (three independent gates)

Live testing is OFF unless ALL of these hold for the run:

1. **Platform kill switch:** `BLACKBOX_LIVE_TESTING=true` in `.env`. Ships
   `false`. With it false, every engagement is read-only/air-gapped, exactly
   like white box. This is the box-level "is this machine even allowed to test
   live" switch.
2. **Per-run opt-in:** the engagement is launched
   `--mode black-box --live --scope-file <scope.conf>`. White box can never be
   `--live`.
3. **Scope:** the `--scope-file` lists the authorized target hosts. An empty or
   absent scope means nothing is in scope and every request is dropped.

Miss any one and the run is read-only.

## Two separate egress lanes

ClawShell has two, deliberately independent, outbound lanes:

| Lane | Component | Purpose |
| --- | --- | --- |
| AI-provider | `quota-guard` | SaaS cost/quota guardrail for the model provider. Mostly idle on local-GPU. Untouched by live testing. |
| Target | `target-gateway` | The only path to a black-box target. Deny-by-default, in-scope-only, rate-limited, approval-gated. |

They share no state or logic; `target-gateway` only reuses quota-guard's proven
*pattern* (a mitmproxy addon plus a loopback control API plus a `.conf` file).
This keeps the cost guardrail and the target boundary from ever interfering with
each other.

## How a live request flows

```
agent (recon/exploit)
  │  calls an MCP tool (http_request / http_fingerprint)
  ▼
openclaw-gateway ──clawshell-mcp──► pentest-tools-mcp
                                      │  routes ALL traffic through the proxy
                                      ▼
                                   target-gateway  (clawshell-target)
                                      │  deny-by-default scope check
                                      │  per-host rate limit + concurrency cap
                                      │  approval gate for state-changing methods
                                      │  JSONL evidence log
                                      ▼
                                   authorized target  (clawshell-target-uplink)
```

`pentest-tools-mcp` has no network path to a target except through
`target-gateway`, and `target-gateway` is the only container on the
target-uplink network. There is no way around it.

## The toolset (safe by design)

The agents reach targets only through the curated `pentest-tools` MCP server.
The toolset is deliberately small and safe:

- `http_request`: a single HTTP(S) request. GET/HEAD/OPTIONS are passive and
  pre-authorized; other methods are attempted but held for approval (below).
- `http_fingerprint`: passive technology/stack fingerprinting from responses.

Design rules for what may ever be added:

- **No external-reporting tools.** Anything that phones home or reports to a
  third party (telemetry, OOB-callback services, cloud recon APIs) is excluded.
  Even if one slipped in, the deny-by-default gateway drops any out-of-scope
  host, so it structurally cannot report out.
- **No destructive tools.** Tools that can damage a target when misused
  (aggressive scanners, injection/exploitation frameworks, password crackers)
  are excluded. Intrusive-but-useful tools, if ever added, sit behind the
  approval gate as Tier 1.

## Risk tiers

| Tier | Examples | Policy |
| --- | --- | --- |
| **0, passive/idempotent** | GET/HEAD/OPTIONS, fingerprinting | Auto-allowed within scope and rate. |
| **1, state-changing/intrusive** | POST/PUT/DELETE/PATCH, auth attempts | Held by the gateway (`approval_required`); a human must approve each one. |
| **2, forbidden** | out-of-scope hosts, internal/loopback/metadata addresses, encoded path traversal, destructive/DoS payloads, exfiltration, persistence | Dropped at the gateway; never allowed. |

The gateway also hardens the boundary against smuggling: an in-scope hostname
that resolves to a loopback, link-local (including cloud metadata
`169.254.169.254`), private, or reserved address is refused (SSRF / DNS-rebind
protection); requests carrying encoded path traversal (`%2e%2e`, `%2f`) are
refused outright; and the approval gate is evaluated against the *effective*
HTTP method, so a Tier 0 `GET` cannot tunnel a `DELETE` through a
method-override header.

If the agent believes any action could break, disrupt, or degrade the target, it
must ask the operator first regardless of tier.

## Scope file

Copy `config/engagement-scope.conf.example` and list the spec-authorized hosts,
one per line:

```
app.example-target.com:443    # rate: 3
api.example-target.com:443
*.staging.example-target.com:443
```

- `host[:port]` or `*.suffix[:port]`, `#` for comments (same format as
  `config/allowlist.conf`).
- A trailing `# rate: N` sets that host's request cap to N req/s (before the
  safety factor), for honoring a spec-stated rate limit.
- The agents cannot edit this file. the launcher stages it read-only into
  `target-gateway`. Only you change scope.

## Rate limiting

The gateway caps requests per host so testing never slows or trips a target:

- The cap is the host's `# rate:` directive if present, else
  `TARGET_RATE_DEFAULT` (default 5 req/s).
- It is always multiplied by `TARGET_RATE_SAFETY_FACTOR` (default 0.8) to stay
  comfortably under the stated limit.
- `TARGET_MAX_CONCURRENCY` (default 2) caps simultaneous in-flight requests.
- The gateway additionally backs off when the target returns `429`, `503`, or a
  `Retry-After`, honoring the target's own signals.

## The approval flow

When an agent issues a Tier 1 (state-changing) request, the gateway refuses it
with `approval_required:<descriptor>`, where the descriptor is a stable token
like `POST api.example-target.com:443/login` (method, host:port, full
normalized path). The agent surfaces this to you and pauses.

You review and, if appropriate, approve it:

```bash
./scripts/scope.sh status                              # active engagement, scope, approvals
./scripts/scope.sh approve 'POST api.example-target.com:443/login'
./scripts/scope.sh revoke  'POST api.example-target.com:443/login'
```

The approval applies to exactly that method + endpoint path (not to sibling
endpoints and not to a verb smuggled through a method-override header), takes
effect on the agent's next attempt, and is cleared when the engagement ends.

## Running an armed live engagement

```bash
# 1. In .env
BLACKBOX_LIVE_TESTING=true

# 2. Author the scope from the signed rules of engagement
cp config/engagement-scope.conf.example config/engagement-scope.conf
$EDITOR config/engagement-scope.conf

# 3. Launch
./scripts/pentest-task.sh \
    --mode black-box --live \
    --scope-file config/engagement-scope.conf \
    --spec engagement-spec.md \
    --target https://github.com/you/target      # optional; omit for URL-only specs

# 4. Approve Tier 1 actions as they are requested
./scripts/scope.sh approve '<descriptor>'
```

The launcher brings up the `blackbox-live` profile (`target-gateway` +
`pentest-tools-mcp`), attributes the engagement, runs the team, then clears the
engagement, stops those services, and removes the staged scope when the task
finishes.

## What is still guaranteed

Even with live testing armed:

- The target **code** on disk (`engagement/target/`) stays read-only. the only
  file any agent writes is the markdown report under `reports/`.
- Nothing reaches a host outside the authorized scope, including any attempt to
  report results off-box.
- No action that could be destructive runs without explicit human approval.
- The AI-provider cost guardrail (`quota-guard`) and per-task quota/runtime caps
  continue to apply unchanged.

## Evidence

Every forwarded and every denied request is appended to a JSONL evidence log
under `logs/target-gateway/` for inclusion in the report. There is no external
reporting of any kind.
