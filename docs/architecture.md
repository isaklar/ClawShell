# Architecture

This document is the single source of truth for *why* this system is built the way
it is. Read it before changing network rules, Docker security settings, or the
quota-guard. If you are an AI/recon picking this repo up cold, start here.

## 1. What this actually is

A small **always-on, read-only code security analysis / penetration-testing
platform** driven by an autonomous agent team
([OpenClaw](https://github.com/openclaw/openclaw), MIT-licensed, real upstream
project, verified against `github.com/openclaw/openclaw` and
`docs.openclaw.ai`) running on a dedicated host (platform-independent; any
modern Linux with Docker) on your network.

An engagement is a **requirement spec** (what to test, the rules of
engagement, the required report format) plus the **target code** that ships
with it. A four-agent pentest team, a Lead Pentester (`main`) plus `recon`,
`exploit`, and `reporter` specialists (see `docs/pentest-team.md`), analyzes
the target against the spec and produces a single markdown findings report.

**Scope: source code, not live systems.** ClawShell performs **static analysis
of code**, not live/dynamic testing (DAST) of running systems. The subject of an
engagement is always the code at `engagement/target/`. Specs written for a live
web pentest (a list of URLs/hosts to probe, no source) are **out of scope**: the
agents have no network route to such targets and never attempt active testing.
When a spec references live endpoints, the team maps each to its handler in the
provided code and reasons there; if no code is provided, it records the item as
out of scope in the report and asks for the source.

**The one hard rule: this is strictly read-only.** The agents may only *read*
the target code, mounted **read-only** (`:ro`) at `engagement/target/`, so the
filesystem itself rejects any write. They must never modify, patch, "fix",
refactor, delete, or write to the target, and never run destructive, exploit,
exfiltration, or state-changing actions (including probing/scanning live hosts).
Findings are confirmed by static
analysis and careful reasoning, not by running exploits. The **only** artifact
any agent writes is the markdown report under `reports/`; remediation
suggestions live there as code snippets, never applied to the project.

**The intelligence can be local or external.** By default
(`MODEL_PROVIDER=local-gpu`) inference runs **entirely on this box** on an
NVIDIA **RTX 6000 Ada 96 GB** GPU: the `local-llm` service serves an
OpenAI-compatible API (vLLM) from a model kept on-box, over the internal
`clawshell-inference` Docker network, so the engagement data (target code,
spec, findings) never leaves the machine to a third-party provider, no API
key, no model-provider egress. An **AMD Radeon** card works too
(`LOCAL_LLM_BACKEND=amd-rocm`, served by Ollama/ROCm as `local-llm-amd`). It
can **still** run on any hosted provider
(`github-copilot`/`anthropic`/`openai`/`custom`) by changing `MODEL_PROVIDER`;
local-GPU is simply the default. See `docs/credentials.md` and `docs/gpu.md`.
The host exists to give that model a **safe place to analyze**: read repos,
reason about code, and write one report, all boxed in by host-level and
network-level containment.

**Important honesty note about scope:** OpenClaw's own sandboxing
(`agents.defaults.sandbox`, Docker/Podman/SSH backend) reduces blast radius for
*tool execution* but its docs explicitly say "this is not a perfect security
boundary" and "OpenClaw is not a hostile multi-tenant security boundary." We do
not treat it as one. This repository adds an outer layer of host-level and
network-level containment *around* OpenClaw so that even a fully compromised or
malfunctioning OpenClaw Gateway process cannot reach the rest of your LAN, your
host filesystem, or burn unlimited AI spend (or, with local-GPU, unlimited GPU
time).

We also did not find documented, built-in per-turn "max iterations" or
"max AI requests per task" controls in OpenClaw's own configuration reference.
We do not invent one. Instead, per-task budgets and circuit-breaking are
implemented in **quota-guard**, a component we own and control, sitting on the
network path between OpenClaw and the internet (see §7). Per-task ceilings
(`MAX_ITERATIONS_PER_TASK` / `MAX_AI_REQUESTS_PER_TASK` / `MAX_TASK_RUNTIME`)
still apply under local-GPU, they also bound GPU time, even though local
inference itself needs no egress and is not proxied through quota-guard.

## 2. Trust boundaries

```
┌───────────────────────────────────────────────────────────────────────┐
│ Home LAN (untrusted from the agent's perspective, except allowlist)   │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │ Host, Linux (trusted: you have SSH/root here)                     │ │
│  │                                                                   │ │
│  │  systemd ── docker compose ── nftables (host firewall)            │ │
│  │                                                                   │ │
│  │  ┌───────────────────┐   docker network: clawshell-egress (internal) │ │
│  │  │ openclaw-gateway   │──────────────┐                            │ │
│  │  │ (untrusted:        │              │                            │ │
│  │  │  runs model output,│   ┌──────────▼─────────┐                  │ │
│  │  │  reads target code,│   │ quota-guard          │  allowlist +    │ │
│  │  │  arbitrary shell)  │   │ (mitmproxy egress    │  circuit        │ │
│  │  │  non-root, no      │   │  proxy, trusted:     │  breaker +      │ │
│  │  │  docker.sock,      │   │  we own the code)    │  request        │ │
│  │  │  read-only rootfs  │   └──────────┬───────────┘  counters       │ │
│  │  └───────────────────┘              │                            │ │
│  │           │ tool exec sandbox        │ only allowlisted           │ │
│  │           ▼                          │ HTTPS destinations         │ │
│  │  ┌───────────────────┐               ▼                            │ │
│  │  │ per-session Docker │      Internet: GitHub (optional target     │ │
│  │  │ sandbox container  │      clone), hosted model provider          │ │
│  │  │ (OpenClaw sandbox  │      (optional, local-GPU is default)      │ │
│  │  │  backend, isolated │      ── NOT reachable: router, NAS, IoT, │ │
│  │  │  network)          │         other LAN hosts (default deny)   │ │
│  │  └───────────────────┘                                            │ │
│  │                                                                   │ │
│  │  On-box GPU inference (default): local-llm (RTX 6000 Ada, vLLM)   │ │
│  │  on the internal clawshell-inference network, NO internet route, │ │
│  │  not proxied through quota-guard; engagement data stays on-box.    │ │
│  │                                                                   │ │
│  │  Explicitly allowlisted internal LAN service (optional):          │ │
│  │  (reached only via quota-guard/allowlist rule you add yourself)   │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

Two trust boundaries matter:

1. **Host vs. container.** The host (your Linux box, your SSH keys, root) is
   trusted. Every container is untrusted by default and gets the minimum
   capabilities to do its job.
2. **OpenClaw vs. everything else.** OpenClaw's Gateway container is the
   component most likely to be influenced by an adversarial target repository,
   README, issue, or dependency (prompt injection, malicious content). It gets
   no host filesystem access outside its workspace volume, no Docker socket,
   and no direct internet access, only egress through quota-guard's allowlist.
   The on-box `local-llm` GPU server is the one thing it reaches directly (over
   the internal, internet-less `clawshell-inference` network); that path
   carries model tokens only and never leaves the box.

## 3. Network architecture

* Host firewall: **nftables**, default-deny inbound, explicit allow for
  SSH (rate-limited) and the LAN subnet you configure for the Control UI port.
* Docker networks:
  * `clawshell-egress` (internal-ish): the only network the OpenClaw Gateway
    container is attached to besides its sandbox-control network. All
    outbound HTTP/HTTPS from the Gateway is forced through `quota-guard`
    (`HTTPS_PROXY`/`HTTP_PROXY` env vars + no direct internet route, the
    network has no default gateway to the internet, only quota-guard has one).
  * `clawshell-sandbox` (internal, no internet egress at all): used by
    OpenClaw's own per-session sandbox containers when `agents.defaults.sandbox`
    is enabled. Read-only analysis commands (grep/read/parse over the staged
    target) run here. It has *no* route to the internet and no route to your
    LAN, only to the workspace volume and, if you explicitly opt in, to a
    single allowlisted internal host (e.g. an internal package mirror) via a
    dedicated rule.
  * `clawshell-inference` (internal, no internet egress at all): the Gateway
    reaches the on-box `local-llm` GPU inference server over this network and
    nothing else is attached to it. It is **not** proxied through quota-guard, local inference has no external spend to circuit-break and no reason to
    reach the internet, so `local-llm` is listed in the Gateway's `NO_PROXY`.
    Only meaningful when `MODEL_PROVIDER=local-gpu`; see `docs/gpu.md`.
* `quota-guard` is the only container with a real internet-facing route, and
  even that route is restricted at the nftables layer to the allowlisted
  destination IPs/ports resolved for the configured hostnames (see
  `docs/networking.md`). Under the default local-GPU provider the Gateway may
  make **no** external calls at all (no hosted model host, no GitHub if the
  target is a local path).
* An internal LAN service, if you choose to allowlist one, is reached from
  OpenClaw only via an explicit allow rule for that one host:port, never a
  general LAN allow.

## 4. Credential architecture

See `docs/security.md` §Credentials for full detail. Summary:

* All secrets live in `/opt/clawshell/secrets/` (host, `600`, owned by a
  dedicated `clawshell` system user), bind-mounted read-only into the
  specific container that needs them. Nothing secret is baked into images or
  committed to git (`.gitignore` + `.env.example` only ever contains
  placeholders, and `install.sh` refuses to run if `.env` is missing but
  contains the literal example values).
* GitHub (optional, only to clone a target): a dedicated **fine-grained
  personal access token** or, preferably, a **GitHub App installation token**
  scoped **read-only** (`contents:read`, `metadata:read`) to only the repos
  you want to analyze, no write scopes are needed because ClawShell never
  pushes, branches, or opens PRs. Not required at all when `--target` is a
  local code drop. See `github/PROVISIONING.md`.
* Model provider key: whatever you choose per `docs/credentials.md`. Under the
  default `MODEL_PROVIDER=local-gpu` there is **no** external key, the Gateway
  uses a dummy value (`clawshell-local`) that vLLM ignores. A real key is only
  needed for the hosted providers. Passed to OpenClaw only via its documented
  env vars / `.env`.

## 5. Filesystem architecture

```
/opt/clawshell/
├── secrets/            # 600, root:clawshell, never bind-mounted rw except where required
├── state/
│   ├── openclaw/        # OpenClaw's ~/.openclaw persistent state (config, sessions)
│   ├── quota-guard/      # circuit breaker + task counters (JSON, persisted)
│   └── local-llm/        # on-box GPU model weight cache (HuggingFace cache; local-gpu only)
├── workspaces/          # agent workspaces incl. engagement/ (staged spec, read-only target, report.md)
├── logs/                # container + quota-guard structured logs
└── backups/             # local backup archives before they're moved off-box
```

Only these directories are bind-mounted into containers, and each container
only gets the subset it needs (e.g. quota-guard never sees `workspaces/`,
OpenClaw never sees `secrets/` in plaintext, see compose file for exact
mounts). The host's `/etc`, `/home/<you>`, `/root`, `/var/lib` are never
mounted into any container.

## 6. Docker security model

* No container is granted `/var/run/docker.sock`. OpenClaw's own Docker-backed
  sandboxing needs *a* Docker socket to spin up per-session containers; we give
  it a **rootless Docker-in-Docker sidecar** (`sandbox-dind`) scoped to the
  `clawshell-sandbox` network instead of the host's real socket. This means a
  container escape from a sandboxed session can, at worst, reach another
  sandbox container inside the nested rootless Docker, not the host, and not
  other LAN hosts. This is the best available trade-off: OpenClaw's sandbox
  backend requires *some* Docker control plane; rootless DinD isolates it from
  the host socket at the cost of one extra hop of virtualization overhead.
* Every container: `user: <non-root uid>`, `read_only: true` root filesystem
  with explicit `tmpfs`/volume exceptions, `security_opt: [no-new-privileges,
  seccomp=default]`, `cap_drop: [ALL]` with only the specific caps added back
  if strictly required (documented per-service in `compose/compose.yml`),
  and CPU/memory/pids limits.
* AppArmor: documented as host-level hardening in `docs/security.md`; enabled
  when the distro's Docker install supports the default `docker-default`
  profile (most mainstream distros do, out of the box), we do not disable it.

## 7. AI quota / cost protection architecture

Goal: a buggy or adversarial agent loop must **physically be unable** to make
unlimited calls to your paid model provider, and the system must know and
persist *why* it stopped.

Because OpenClaw does not expose a documented "requests used this task" hook
we can subscribe to, quota-guard enforces this **on the network path**,
which is the one place we can observe and control every outbound model-provider
call regardless of what OpenClaw's internal agent loop does:

```
OpenClaw Gateway --HTTP(S)_PROXY--> quota-guard (mitmproxy + custom addon) --> Internet
                                         │
                                         ├─ allowlist enforcement (deny by default)
                                         ├─ per-provider-host failure counter
                                         ├─ detects 429 / 401 / 403 / 402,
                                         │  known quota-exhaustion response bodies,
                                         │  and Retry-After / reset headers
                                         ├─ exponential backoff hints surfaced to logs
                                         ├─ circuit breaker (CLOSED → OPEN → HALF_OPEN)
                                         ├─ persists state to state/quota-guard/state.json
                                         └─ exposes /status on a loopback-only control port
```

Task-level budgets (`MAX_AI_REQUESTS_PER_TASK`, `MAX_ITERATIONS_PER_TASK`,
`MAX_TASK_RUNTIME`, `MAX_RETRIES_PER_OPERATION`, `MAX_CONCURRENT_TASKS`) are
enforced by `scripts/pentest-task.sh`, the wrapper you use to submit an
engagement (a requirement spec + a target) to OpenClaw. It:

* creates a task record (id, start time, target, spec, status) in
  `state/quota-guard/tasks/<task-id>.json`,
* tells quota-guard "attribute the next N requests to task
  `<task-id>`" (single in-flight task by default, `MAX_CONCURRENT_TASKS=1`, so attribution by time-window is reliable without needing OpenClaw to pass
  us a header),
* runs the OpenClaw CLI call under `timeout <MAX_TASK_RUNTIME>`,
* polls quota-guard's counters and stops the task (SIGTERM the CLI call,
  mark task `LIMIT_REACHED`) the moment any configured ceiling is hit,
* never auto-retries a failed AI call itself, retries, if any, are entirely
  OpenClaw's own concern up to `MAX_RETRIES_PER_OPERATION`, after which
  quota-guard's circuit breaker will already have opened and further calls are
  short-circuited locally (no network round-trip, no spend) with a
  synthetic `503 circuit_open` response.

When the circuit opens because of a detected quota/rate-limit signal:

* state moves to `QUOTA_EXHAUSTED` (persisted, survives restarts/reboots),
* if the provider response included a trustworthy machine-readable reset time
  (`Retry-After` seconds, or a provider-specific reset timestamp header we
  have an explicit parser for), quota-guard schedules an automatic
  `HALF_OPEN` retry at that time,
* otherwise it stays `PAUSED` and requires `./scripts/quota-guard.sh resume`
  (a deliberate human action), we do not guess.

See `docs/quota-protection.md` for the full state machine, defaults, and the
list of detected error signals per provider.

**Under the default local-GPU provider**, model calls go straight to the
on-box `local-llm` server over `clawshell-inference` and are **not** seen by
quota-guard's circuit breaker (there is no paid provider to protect). The
task-layer budgets above still apply unchanged, they are enforced by
`pentest-task.sh` regardless of provider and bound GPU time the same way they
bound API spend. The circuit breaker remains fully active for any hosted
provider and for GitHub traffic.

## 8. GitHub permissions

See `github/PROVISIONING.md`. Summary: **optional**, only needed to clone a
private GitHub repo as the target. When used, a dedicated bot identity with a
**read-only** fine-grained token or GitHub App (repo allowlist enforced by
quota-guard). ClawShell never pushes, branches, or opens PRs, the target is
cloned host-side, mounted read-only, and only read. For local target paths no
GitHub credential is involved at all.

## 9. Internal LAN service access

ClawShell does not reach your LAN by default: quota-guard rejects all private/
loopback/link-local destinations (SSRF protection). If an engagement genuinely
needs the Gateway to reach one internal host (e.g. an internal git server or a
self-hosted model endpoint), you add a single explicit `host:port` allow rule
with `./scripts/allowlist.sh add`, hot-reloaded by quota-guard. The rule is
scoped to that one host, never a general LAN allow, so nothing else on your
network becomes reachable. See `docs/networking.md`.

## 10. Deployment architecture

`install.sh` is the only supported entry point for a fresh host. It is
idempotent (safe to re-run), and every destructive step requires either an
empty/fresh state or an explicit `--confirm-reset` flag. See
`docs/operations.md` for the full phase breakdown, `update.sh`/rollback
strategy, and `backup.sh`/`restore.sh`.

## 11. Threat model

See `docs/security.md` §Threat model for the full adversarial analysis
(prompt injection, malicious repos/dependencies, credential theft, SSRF,
lateral movement, Docker privilege escalation, destructive commands, runaway
loops, quota exhaustion). Design principle used throughout: **assume the
model output and any target content it reads is hostile**, and verify that the
blast radius of "the agent does something completely unexpected" is bounded to
"one workspace holding a read-only copy of the target and a single markdown
report, and a finite amount of AI/GPU time", never a write to the target,
never the host, never the rest of the LAN.

---

## See also

* [Main README](../README.md): project overview and documentation map
* [Quickstart](quickstart.md): install once, then the three ways to run a pentest
* [GPU](gpu.md): on-box inference (NVIDIA/vLLM, AMD/ROCm), model/VRAM guidance
* [Pentest team](pentest-team.md): the 4 agents, delegation, per-agent models
* [Security](security.md): host hardening, credentials, full threat model
* [Networking](networking.md): Docker topology, egress allowlist, nftables
* [Black-box live testing](blackbox-live-testing.md): scoped egress, target-gateway, approval flow
* [Quota protection](quota-protection.md): circuit breaker, per-task limits
* [Caveman integration](caveman-integration.md): token-reduction skill and proxy
* [Credentials](credentials.md): the model-provider decision
* [Operations](operations.md): install/update/backup/restore/uninstall
* [Testing](testing.md): the regression suite (static, unit, live, manual)
* [Roadmap](roadmap.md): planned, not-yet-built work
