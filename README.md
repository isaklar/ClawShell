# clawshell

```
  ____ _                 ____  _          _ _
 / ___| | __ ___      __/ ___|| |__   ___| | |
| |   | |/ _` \ \ /\ / /\___ \| '_ \ / _ \ | |
| |___| | (_| |\ V  V /  ___) | | | |  __/ | |
 \____|_|\__,_| \_/\_/  |____/|_| |_|\___|_|_|
```

[![CI](https://github.com/isaklar/ClawShell/actions/workflows/ci.yml/badge.svg)](https://github.com/isaklar/ClawShell/actions/workflows/ci.yml)

A small, always-on, hard-sandboxed, **GPU-first code security analysis /
penetration-testing platform**. It runs
[OpenClaw](https://github.com/openclaw/openclaw) (MIT-licensed) in Docker on any
modern Linux host with Docker and systemd.

**Inference runs on the box by default** (`MODEL_PROVIDER=local-gpu`): an on-box
**NVIDIA** GPU (via vLLM) or **AMD Radeon** card (via Ollama/ROCm) serves the
model, so the engagement data (target code, requirement spec, findings) **never
leaves the machine**. It can still run on any hosted provider
(`github-copilot`/`anthropic`/`openai`/`custom`) by changing one variable. See
[docs/gpu.md](docs/gpu.md) and [docs/credentials.md](docs/credentials.md).

**Read-only by default.** A team of four pentest agents analyzes a target
against a requirement spec and **only reads** the code: it never modifies,
patches, refactors, deletes, or runs destructive/exploit actions, and by default
never probes live hosts. The target is mounted read-only (`:ro`); the **only**
artifact any agent writes is a markdown findings report under `reports/`
(remediation ideas appear there as snippets, never applied). A black-box
engagement may optionally be armed for **scoped, approval-gated live testing**
(off by default; see [docs/blackbox-live-testing.md](docs/blackbox-live-testing.md)).
Everything is fenced by a deny-by-default network layer and a quota/circuit
breaker so a runaway agent loop cannot burn unlimited AI spend or GPU time.

**Start here:** [docs/quickstart.md](docs/quickstart.md) to install and run your
first pentest, or [docs/architecture.md](docs/architecture.md) for the trust
boundaries, network diagram, and the reasoning behind every decision.

## What's in this repo

```
clawshell/
├── docs/                    architecture, security, networking, quota-protection, operations, credentials, gpu, pentest-team, testing
├── compose/compose.yml      the whole stack: OpenClaw Gateway, quota-guard, rootless sandbox DinD, local-llm GPU inference
├── quota-guard/             mitmproxy-based egress allowlist + AI-spend circuit breaker (Python)
├── target-gateway/          opt-in black-box live-testing egress boundary (scope, rate limit, approval gate)
├── pentest-tools-mcp/       curated safe-by-design MCP toolset for live testing
├── config/                  OpenClaw config template, agent-workspaces/ (4-agent team), egress allowlist
├── firewall/ systemd/       nftables ruleset + unit templates (rendered by install.sh)
├── scripts/                 install / update / backup / restore / healthcheck / pentest-task / scope / quota-guard / allowlist
└── tests/                   static + unit suite, plus live isolation/circuit-breaker checks
```

## Quick start

```bash
git clone <this-repo> clawshell && cd clawshell
cp .env.example .env && $EDITOR .env      # set LAN_ALLOW_CIDR, MODEL_PROVIDER + GPU/model vars
sudo ./scripts/install.sh                 # idempotent; stages the model onto the GPU
./scripts/healthcheck.sh
```

With the default `MODEL_PROVIDER=local-gpu` there is no external auth or device
login; first start can take a few minutes while weights load. GitHub
credentials are **optional**, only needed to clone a private git `--target`
([github/PROVISIONING.md](github/PROVISIONING.md)). Full walkthrough, including
the GPU driver step and hosted-provider alternatives:
**[docs/quickstart.md](docs/quickstart.md)**.

## Running an engagement

Place the target code at `engagement/target/` and the spec at `engagement/spec/`
(or attach it in chat), then start the analysis **inside OpenClaw** one of three
ways:

1. **Conversationally (primary).** Talk to the **Lead Pentester** in the OpenClaw
   Control UI: *"Run a read-only security analysis of `engagement/target/`
   against this spec and write the report to `reports/report.md`."*
2. **Headless / scriptable.** For CI or batch runs, wrapped in a quota-guarded
   task with hard limits:

   ```bash
   ./scripts/pentest-task.sh --spec ./spec/requirements.md \
     --target ./code-drops/acme-api --mode white-box \
     --max-runtime 2h --max-ai-requests 100
   ```
3. **Over the LAN API.** The gateway exposes OpenAI-compatible endpoints on
   port `18789` (bearer token, firewalled to `LAN_ALLOW_CIDR`); address the Lead
   Pentester as model `openclaw/main`.

An engagement goes to `main` (the Lead Pentester), which plans and delegates to
**Recon**, **Exploit** (static reasoning, no live exploitation), and
**Reporter**. Cancel a headless run with `./scripts/pentest-task.sh cancel
<task-id>`. Full detail: **[docs/quickstart.md](docs/quickstart.md)** and
**[docs/pentest-team.md](docs/pentest-team.md)**.

### Engagement modes

The Lead Pentester fixes the mode **before** any analysis (from the spec, the
`--mode` flag, or by asking you):

* **White box (default):** full-knowledge review; everything under
  `engagement/target/` is in scope unless the spec excludes it.
* **Black box:** external-attacker viewpoint with **strict scope**, only the
  assets the spec lists as in scope, even though the full source is present. With
  no code (omit `--target`) it produces a spec/design-level assessment (threat
  model + prioritized test plan, every item flagged as a hypothesis).

Both are read-only static analysis by default. A black-box engagement may
additionally be armed for **scoped live testing** (`BLACKBOX_LIVE_TESTING=true`
plus `--live --scope-file <scope.conf>`): a deny-by-default `target-gateway`
forwards traffic **only** to spec-authorized hosts, agents reach them **only**
through the curated `pentest-tools` MCP toolset, passive requests are
rate-limited, and any state-changing action is **held for human approval**
(`./scripts/scope.sh approve '<descriptor>'`). White box is always read-only.
Full detail: **[docs/blackbox-live-testing.md](docs/blackbox-live-testing.md)**.

## Safety model

* **Security > agentic capability > quota protection > reproducibility > simple
  deployment > maintainability > functionality.** Every trade-off in
  [docs/architecture.md](docs/architecture.md) is made in that order: we'd rather
  a task stop too early than burn your budget, and rather the agent lack access
  than have more than it needs.
* **Deny by default, everywhere.** Network egress, host filesystem access, Docker
  socket access, and LAN reachability are all closed unless explicitly opened.
  See [docs/security.md](docs/security.md) for the full threat model.
* **No invented capabilities.** Where upstream tools lack a feature we needed, we
  say so and build an honest alternative ([docs/credentials.md](docs/credentials.md),
  [docs/quota-protection.md](docs/quota-protection.md)).

## Day-2 operations & testing

* **Operations** (update, rollback, backup, restore, uninstall, allowlist,
  quota resume): quick-reference table and phase-by-phase detail in
  **[docs/operations.md](docs/operations.md)**.
* **Tests:** `./tests/run-all.sh` runs the static + Python unit suite anywhere
  (no deployed host) and auto-runs live isolation/circuit-breaker checks if a
  running gateway is detected. See **[docs/testing.md](docs/testing.md)**.

## Documentation map

* [docs/quickstart.md](docs/quickstart.md): install once, then the three ways to run a pentest (chat, headless script, LAN API)
* [docs/architecture.md](docs/architecture.md): trust boundaries, all architecture decisions, the diagram
* [docs/gpu.md](docs/gpu.md): on-box inference (NVIDIA/vLLM, AMD/ROCm), LOCAL_LLM_* vars, model/VRAM guidance, switching to a hosted provider
* [docs/pentest-team.md](docs/pentest-team.md): the 4-agent team (Lead + Recon/Exploit/Reporter), delegation, per-agent models, read-only/report-only rules
* [docs/security.md](docs/security.md): host hardening, credentials, full threat model
* [docs/networking.md](docs/networking.md): Docker network topology, egress allowlist, nftables/DOCKER-USER
* [docs/blackbox-live-testing.md](docs/blackbox-live-testing.md): opt-in scoped live testing, the two egress lanes, target-gateway, the pentest-tools MCP toolset, risk tiers, approval flow
* [docs/quota-protection.md](docs/quota-protection.md): circuit breaker state machine, per-task limits, defaults
* [docs/caveman-integration.md](docs/caveman-integration.md): [caveman](https://github.com/JuliusBrussee/caveman) token-reduction skill and experimental proxy
* [docs/credentials.md](docs/credentials.md): the model-provider decision (local-GPU by default; hosted providers optional)
* [docs/operations.md](docs/operations.md): install/update/backup/restore/uninstall, rollback strategy, known limitations
* [docs/testing.md](docs/testing.md): the regression suite (static, Python unit, live-host, manual)
* [github/PROVISIONING.md](github/PROVISIONING.md): GitHub bot credential setup (optional, only for private git targets)
* [docs/roadmap.md](docs/roadmap.md): planned, not-yet-built work

## License

MIT, see [LICENSE](LICENSE). OpenClaw is a separate MIT-licensed upstream
project; this repo does not redistribute its source, only deploys its published
images.
