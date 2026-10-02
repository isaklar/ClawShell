# clawshell

A small, always-on, hard-sandboxed, **GPU-first code security analysis /
penetration-testing platform**. Platform-independent; runs on any modern
Linux host with Docker and systemd.

Runs [OpenClaw](https://github.com/openclaw/openclaw) (MIT-licensed, verified
real upstream project) in Docker. **Inference runs on the box
by default** (`MODEL_PROVIDER=local-gpu`): an on-box **NVIDIA** GPU serves the
model through a local vLLM service, or an **AMD Radeon** card via Ollama/ROCm
(`LOCAL_LLM_BACKEND=amd-rocm`), so the
engagement data (the target code, the requirement
spec, and the findings) **never leaves the machine** for a third-party
provider. Pick a model that fits your card's VRAM; see `docs/gpu.md` for the
backend setup and per-GPU model/VRAM guidance. It can **still run on any AI
provider** (`github-copilot`/`anthropic`/`openai`/`custom`, see
`docs/credentials.md`) by changing one variable, but local-GPU is the headline
default.

ClawShell is strictly **read-only**, and its scope is **static analysis of
source code**, not live/dynamic testing of running systems (DAST). A team of
four pentest agents analyzes a target against a requirement spec and **only
reads** the target code; it never modifies, patches, "fixes", refactors,
deletes, or runs destructive/exploit actions against it, and it never probes,
scans, or sends requests to live hosts. If a spec only lists URLs/endpoints with
no code, that work is out of scope: the agents note it in the report and ask for
the source instead. The target is mounted **read-only** (`:ro`) at
`engagement/target/` so the filesystem itself rejects any write, and the
**only** artifact any agent writes is a markdown findings report under
`reports/` (remediation suggestions appear there as code snippets, never
applied to the project). All of this is boxed in by a deny-by-default network
layer and a quota/circuit breaker that makes it physically impossible for a
runaway agent loop to burn unlimited AI spend (and, with local-GPU, unlimited
GPU time).

**Start here:** `docs/quickstart.md` to install and run your first pentest, or
`docs/architecture.md` for the trust boundaries, network diagram, Docker
security model, and the full reasoning behind every decision below.

## What's in this repo

```
clawshell/
├── docs/                    architecture, security, networking, quota-protection, operations, credentials, gpu, pentest-team
├── compose/compose.yml      the whole stack: OpenClaw Gateway, quota-guard, rootless sandbox DinD, local-llm GPU inference server
├── quota-guard/             mitmproxy-based egress allowlist + AI-spend circuit breaker (Python)
├── config/                  OpenClaw config template, agent-workspaces/ (4-agent PENTEST team role instructions), egress allowlist, per-host allowlist.d/
├── firewall/                nftables ruleset template (rendered by install.sh)
├── systemd/                 unit templates so the stack survives reboots
├── scripts/                 install / uninstall / update / backup / restore / healthcheck / pentest-task / setup-team / quota-guard / allowlist
├── github/PROVISIONING.md   how to mint the agent's GitHub credential (optional, only to clone private git targets)
└── tests/                   isolation + circuit-breaker verification scripts
```

## Quick start

1. **(Optional) Mint the agent's GitHub credential**, only needed if you
   point `--target` at a **private** GitHub repo to analyze. For local code
   drops (`--target /path/to/code`) and local-GPU inference you need no GitHub
   credentials at all. If you do need it, follow `github/PROVISIONING.md`
   (fine-grained PAT or GitHub App, scoped read-only to the repos you want to
   clone).
2. Clone and configure:

   ```bash
   git clone <this-repo> clawshell
   cd clawshell
   cp .env.example .env
   $EDITOR .env
   ```

   At minimum, set:
   * `LAN_ALLOW_CIDR`, your actual LAN subnet (not `0.0.0.0/0`).
   * `MODEL_PROVIDER=local-gpu` (the default) plus the GPU/model vars, `LOCAL_LLM_MODEL` (default `Qwen/Qwen2.5-Coder-32B-Instruct`),
     `LOCAL_LLM_MAX_MODEL_LEN`, `LOCAL_LLM_GPU_MEM_UTIL`, and
     (only for gated/private HF models) `HUGGING_FACE_HUB_TOKEN`. See
     `docs/gpu.md`. To use a hosted provider instead, set `MODEL_PROVIDER` to
     `github-copilot`/`anthropic`/`openai`/`custom` and the matching key, see `docs/credentials.md`.
   * `GITHUB_AGENT_USERNAME` / `GITHUB_AGENT_TOKEN` / `GITHUB_ALLOWED_REPOS`, **optional**, only if you clone a private git target. When set,
     `GITHUB_ALLOWED_REPOS` is **enforced**, not just informational:
     `quota-guard` blocks clone/fetch calls to any GitHub repo not on this
     list (see `docs/networking.md#github-repo-scope-enforcement`). Leave
     empty if you only ever analyze local code drops.
3. Install:

   ```bash
   sudo ./scripts/install.sh
   ```

With the default `MODEL_PROVIDER=local-gpu`, `install.sh` installs the NVIDIA
Container Toolkit (if needed), starts the on-box `local-llm` vLLM service, and
loads the model onto the GPU, no external auth, no device login. First start
can take several minutes while weights download/load (watch with
`docker compose -f compose/compose.yml --profile local-gpu logs -f local-llm`).
If you switch to `MODEL_PROVIDER=github-copilot`, `install.sh` instead pauses
with a one-time device-login command. See `docs/gpu.md` and
`docs/credentials.md`.

That's the whole install. `install.sh` is idempotent, re-running it only
reconciles drift, never destroys existing state, and any genuinely destructive
step requires `--confirm-reset`. See `docs/operations.md` for the exact
14-phase breakdown of what it does.

Afterwards:

```bash
./scripts/healthcheck.sh
```

```
== Containers ==
clawshell-openclaw-gateway    running
clawshell-quota-guard         running
clawshell-sandbox-dind        running
clawshell-local-llm           running

== Quota-guard ==
Current task:        (none running)
Quota state:          OK

== Network ==
Network:              HEALTHY (0 blocked connections in last hour)

== GitHub ==
GitHub:                NOT CONFIGURED (optional, local targets)
```

## Running an engagement

There are three ways to start an engagement; all run the analysis **inside
OpenClaw**, the script and the API are just optional launchers on top of the
same agents.

**1. Conversationally (primary).** Put the target code under test at
`engagement/target/` (it is mounted read-only into the agents), open the
OpenClaw Control UI, and talk to the **Lead Pentester**:

> *Attach `requirements.md` in the chat →* "Run a read-only security analysis
> of `engagement/target/` against this spec and write the report to
> `reports/report.md`."

The requirement spec can be **attached directly in the chat** (OpenClaw's
Control UI supports PDF / Markdown / text document uploads) or dropped at
`engagement/spec/`. No per-run script needed. If the spec does not state the
engagement mode, the Lead Pentester will ask **black box or white box** before
it starts (see below).

**2. Headless / scriptable.** For CI or batch runs, use the launcher, which
also wraps the run in a quota-guard task with hard limits:

```bash
./scripts/pentest-task.sh \
  --spec ./engagements/acme-api/requirements.md \
  --target ./code-drops/acme-api \
  --mode white-box \
  --max-runtime 2h --max-ai-requests 100
```

`--spec` is the requirement spec (scope, rules of engagement, required report
format); `--target` is a local path or a git URL; `--mode` is `white-box`
(default) or `black-box` (see below). The launcher stages the spec
at `engagement/spec/<file>` and the target at `engagement/target/` (host-side
copy for local paths, host-side shallow `git clone` for URLs, the sandbox has
no egress to clone), both mounted **read-only**, then runs the lead pentester
and writes `reports/<task-id>.md`.

**3. Over the LAN API.** The OpenClaw gateway exposes OpenAI-compatible
endpoints on port `18789` (bearer token in `secrets/gateway_token`, firewalled
to `LAN_ALLOW_CIDR`), so another machine on the network can drive an engagement.
Place the target and spec under `engagement/` first, then target the Lead
Pentester as the model `openclaw/main`:

```bash
curl -s http://<host>:18789/v1/chat/completions \
  -H "Authorization: Bearer <gateway-token>" \
  -H 'Content-Type: application/json' \
  -d '{ "model": "openclaw/main",
        "messages": [{ "role": "user",
          "content": "Analyze the code in engagement/target/ against the spec in engagement/spec/ and write your findings to reports/report.md. Read-only: do not modify the target." }] }'
```

`GET /v1/models` lists the addressable agents (`openclaw/main`,
`openclaw/recon`, …). Full walkthrough, getting the token, listing models, and
calling it from another host, is in `docs/quickstart.md` (Way C).

By default an engagement goes to `main`, the **Lead Pentester** that reads
the spec, plans the engagement, and delegates to three isolated specialists: **Recon** (`recon`, attack-surface mapping), **Exploit** (`exploit`,
*vulnerability confirmation & impact analysis* by static reasoning, **no live
exploitation**), and **Reporter** (`reporter`, writes the findings report).

### Black box vs white box

Every engagement runs in one of two modes. The Lead Pentester fixes the mode
**before** any analysis: it uses what the spec says, or the `--mode` flag on a
headless run, and otherwise asks you in chat.

* **White box (default): full-knowledge review.** The agents may use the entire
  target, all source, config, and internal docs. Everything in `engagement/target/`
  is in scope unless the spec explicitly excludes it.
* **Black box: external-attacker perspective, strict scope.** The agents analyze
  **only** the assets, endpoints, and interfaces the spec explicitly lists as in
  scope and treat everything else as out of scope, even though the full source is
  present. In this mode scope is a **hard boundary**: if the spec is ambiguous, or
  a lead points at code that is not clearly in scope, the team stops and asks
  rather than widening scope on its own. Black box does **not** require source:
  if the spec ships only URLs/endpoints and no code (omit `--target`), the team
  produces a spec/design-level assessment instead: a threat model, likely
  weakness classes, and a prioritized test plan, with every item flagged as an
  unvalidated hypothesis.

Both modes are strictly **read-only static analysis**; "black box" here means
scope discipline and attacker viewpoint, not live/dynamic testing (always out of
scope). The active mode is recorded in the report's scope section.
Pass `--agent recon|exploit|reporter` to target a specialist directly instead.
See `docs/pentest-team.md` for the full team topology, delegation flow, and
how to add/remove/reassign models per agent.

This is **read-only by design**: the `engagement/` mount is `:ro`, so no agent
can modify, patch, "fix", refactor, delete, or write to the target even if
asked, the only writable output is the report under `reports/`. Cancel a
running headless engagement with `./scripts/pentest-task.sh cancel <task-id>`.

The task is hard-capped on runtime and AI-request count (which, under
local-GPU, also bound GPU time), and its status/stop reason is always
recorded. Full detail: `docs/quota-protection.md`.

## Why this looks the way it does

* **Security > agentic capability > quota protection > reproducibility >
  simple deployment > maintainability > functionality.** Every trade-off in
  `docs/architecture.md` was made in that order. We'd rather a task stop too
  early than a bug burn your AI budget for hours, and we'd rather the agent
  be unable to do something than have more access than it needs.
* **We didn't invent capabilities.** Where OpenClaw, GitHub, Docker, or Home
  Assistant don't document a feature we needed (a native GitHub Copilot
  provider, a per-task iteration counter), we say so explicitly and built an
  honest alternative instead, see `docs/credentials.md` and
  `docs/quota-protection.md`.
* **Deny by default, everywhere.** Network egress, host filesystem access,
  Docker socket access, LAN reachability, all closed unless explicitly
  opened. See `docs/security.md` for the full threat model.

## Day-2 operations

| Task | Command |
| --- | --- |
| Update to a newer commit/image | `./scripts/update.sh` (auto rollback on failed healthcheck) |
| Roll back manually | `./scripts/update.sh --rollback` |
| Back up state/config | `./scripts/backup.sh` |
| Restore | `./scripts/restore.sh backups/clawshell-<ts>.tar.zst` |
| Uninstall | `./scripts/uninstall.sh [--purge]` |
| Add an internal LAN service to the allowlist | `./scripts/allowlist.sh add <host:port>` |
| Resume after quota exhaustion | `./scripts/quota-guard.sh resume` |

Full detail for all of the above: `docs/operations.md`.

## Testing / regression checks

```bash
./tests/run-all.sh
```

Runs the full suite: static/unit checks (script syntax, install.sh phase
numbering, `.env.example` var coverage, allowlist consistency, secrets-hygiene,
`docker compose config` validation, credential-provider decision logic) always
run, no deployed host needed, safe on a dev laptop. Isolation/circuit-breaker
tests that need a live deployment (`test-filesystem-isolation.sh`,
`test-network-isolation.sh`, `test-quota-guard-circuit-breaker.sh`) run
automatically too if they detect a running `clawshell-openclaw-gateway`
container, otherwise they're reported as skipped. Run individual test files
directly (e.g. `./tests/test-static-validation.sh`) for faster iteration.

## Documentation map

* `docs/quickstart.md`: the fast path: install once, then the three ways to run a pentest (chat, headless script, LAN API)
* `docs/architecture.md`: trust boundaries, all 11 architecture decisions, the diagram
* `docs/gpu.md`: on-box inference: NVIDIA/vLLM and AMD/ROCm backends, LOCAL_LLM_* vars, model/VRAM guidance, switching to a hosted provider
* `docs/pentest-team.md`: the 4-agent pentest team (Lead Pentester + Recon/Exploit/Reporter), delegation, per-agent models, the read-only/report-only rules, sandboxing
* `docs/security.md`: host hardening, credentials, full threat model
* `docs/networking.md`: Docker network topology, egress allowlist, nftables/DOCKER-USER
* `docs/quota-protection.md`: circuit breaker state machine, per-task limits, defaults
* `docs/caveman-integration.md`: [caveman](https://github.com/JuliusBrussee/caveman) token-reduction skill (on by default) and experimental proxy (off by default)
* `docs/credentials.md`: the model-provider decision (local-GPU by default; hosted providers optional)
* `docs/operations.md`: install/update/backup/restore/uninstall phase-by-phase, rollback strategy, known limitations
* `github/PROVISIONING.md`: GitHub bot credential setup (optional, only for private git targets)
* `docs/roadmap.md`: planned, not-yet-built work (e.g. integrating OWASP Dependency-Check / CVE scanners)

## License

MIT, see `LICENSE`. OpenClaw is a separate MIT-licensed upstream project;
this repo does not redistribute its source, only deploys its published images.
