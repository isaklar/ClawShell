# Networking

## Overview

```
Internet
   ▲
   │ only quota-guard has a default route out
   │
┌──┴─────────────┐        ┌────────────────────┐
│ quota-guard     │        │ Linux host          │
│ (mitmproxy)     │        │ nftables: default   │
│ egress allowlist│        │ deny inbound        │
└──┬──────────────┘        └─────────┬───────────┘
   │ docker network: clawshell-egress    │ LAN CIDR allow: SSH, Control UI
   │ (no default route to internet;  │
   │  only quota-guard's veth does)  │
┌──▼──────────────┐                  │
│ openclaw-gateway │◄─────published──┘  (only if you bind beyond loopback)
│                  │   port 18789 (Control UI), LAN-restricted
└──┬───────────────┘
   │ sandbox-control (talks to sandbox-dind's Docker API over TCP on
   │ clawshell-sandbox network only, not the host socket)
┌──▼───────────────┐        docker network: clawshell-sandbox
│ sandbox-dind      │        (rootless Docker-in-Docker; NO internet route,
│ (rootless DinD)   │◄────►  NO route to clawshell-egress, NO route to your LAN)
└──┬───────────────┘
   │ spawns
┌──▼───────────────┐
│ per-session       │
│ sandbox container │  runs agent-directed shell/build/test commands
└───────────────────┘
```

## Docker networks

| Network | Internet egress | Reaches host LAN | Purpose |
| --- | --- | --- | --- |
| `clawshell-egress` | Only via quota-guard (no direct route) | No | Gateway ⇄ quota-guard |
| `clawshell-sandbox` | **None** | No (except an optional explicit allowlist.d/ rule, see below) | OpenClaw's tool-execution sandbox containers via nested rootless DinD |
| `clawshell-control` (internal, loopback-published) | N/A | Published to LAN CIDR only, if you choose | Control UI / Gateway API |
| `clawshell-inference` (internal) | **None** | No | Gateway ⇄ `local-llm` GPU model server (only when `MODEL_PROVIDER=local-gpu`) |
| `clawshell-mcp` (internal) | **None** | No | Gateway ⇄ `pentest-tools-mcp` (only when the `blackbox-live` profile is up) |
| `clawshell-target` (internal) | **None** | No | `pentest-tools-mcp` ⇄ `target-gateway` (black-box live lane) |
| `clawshell-target-uplink` | Only via `target-gateway` (deny-by-default, in-scope only) | No | `target-gateway` → authorized live-testing targets |

> **GPU inference stays on-box.** When `MODEL_PROVIDER=local-gpu` (the default),
> the model server, `local-llm` (NVIDIA/vLLM) or `local-llm-amd` (AMD/ROCm,
> `LOCAL_LLM_BACKEND=amd-rocm`), is attached **only** to the internal
> `clawshell-inference` network with no published ports and no internet route, > reachable solely by `openclaw-gateway`. Model tokens never traverse
> quota-guard (there is no external spend), and engagement data never leaves the
> host. See `docs/gpu.md`.

> **Two separate egress lanes.** quota-guard is the **AI-provider** lane (a SaaS
> cost/quota guardrail, mostly idle on local-GPU). The last three networks above
> form a **completely separate target lane** used only for opt-in black-box live
> testing: `target-gateway` is the single container that can reach a target, and
> it enforces deny-by-default, in-scope-only, rate-limited, approval-gated egress
> on `clawshell-target-uplink`. The two lanes share no state. The `blackbox-live`
> Compose profile (and therefore these networks carrying any traffic) is up only
> for an armed live engagement. See `docs/blackbox-live-testing.md`.

## Egress allowlist (quota-guard)

Deny-by-default. The only destinations OpenClaw's Gateway can reach (through
quota-guard) are, at install time:

* `github.com`, `api.github.com`, `*.githubusercontent.com`,
  `codeload.github.com`, repository operations, GitHub API
* `github.com`'s device/OAuth token endpoints as required by your chosen
  GitHub credential flow (fine-grained PAT needs none of these at runtime;
  GitHub App installation token refresh needs `api.github.com` only)
* Whichever single model-provider API host matches your `MODEL_PROVIDER`
  choice (`docs/credentials.md`) in `config/allowlist.conf`, pick one
  primary; do not allowlist every provider "just in case":
  * `MODEL_PROVIDER=github-copilot` (default) → `*.githubcopilot.com`
    (already covered by `github.com`/`api.github.com` above for auth)
  * `MODEL_PROVIDER=anthropic` → `api.anthropic.com`
  * `MODEL_PROVIDER=openai` → `api.openai.com`
* Container registry hosts only if `update.sh` needs to pull images from
  inside the network namespace (`ghcr.io`, `docker.io`/`registry-1.docker.io`,
  `production.cloudflare.docker.com`), this is only exercised by
  `update.sh` on the host, not by the Gateway container, so it is **not**
  part of the Gateway's runtime allowlist
* An internal LAN service: **not** in the default allowlist. If an engagement
  needs one (e.g. an internal git server or self-hosted model endpoint), you
  add it explicitly:

  ```bash
  ./scripts/allowlist.sh add git.internal.example:443
  # or an internal IP:
  ./scripts/allowlist.sh add 192.168.1.50:8443
  ```

  This writes one line to `config/allowlist.d/<name>.conf`
  (git-ignored, it's host-specific) and quota-guard hot-reloads it.
* `html.duckduckgo.com`, `duckduckgo.com`, back the `web_search` tool for
  `main` and `recon` (see
  `docs/pentest-team.md#tools-what-all-four-agents-can-actually-call`).
  `exploit`/`reporter` can't call `web_search` at all, regardless of this
  allowlist entry, because the tool itself is denied for them.
* `registry.npmjs.org`, one-time only, to install the DuckDuckGo plugin
  package (`scripts/setup-team.sh`). Safe to comment out again after the
  first successful install; re-enable temporarily to upgrade the plugin.
* `ANY_HTTPS` (special entry, not a hostname), allows any host on port 443.
  Backs `main`'s `web_fetch` tool (read the full page of a URL found via
  search, not just a snippet). **Shipped commented out** (disabled): the
  platform is strict deny-by-default. See
  [ANY_HTTPS opt-in (web_fetch)](#any_https-opt-in-web_fetch) below before
  enabling it.

Everything else is blocked and logged (`logs/quota-guard/blocked.log`), with
source, destination, and timestamp, visible in `healthcheck.sh` output as a
count, and in full via `docker compose logs quota-guard | grep BLOCKED`.

### GitHub repo-scope enforcement

Host-level allowlisting (above) only decides *which GitHub hosts* are
reachable, not *which repos*. `GITHUB_ALLOWED_REPOS` in `.env` is enforced on
top of that, inside `quota-guard`: it terminates TLS for allowlisted
destinations already (that's how the circuit breaker reads response bodies
for quota-exhaustion signals), so it can also read the decrypted request path
for `github.com`/`api.github.com`/`codeload.github.com` and check it against
the list, no separate mechanism needed.

This matters because git clone/fetch/push and GitHub API calls run from the
Gateway process itself (proxied through quota-guard), not from inside the
network-isolated per-session sandbox (see `docs/architecture.md` §3), so
this is the one place in the whole stack that can actually see and gate every
git network operation an agent makes, regardless of which agent or session
triggered it.

Enforcement is deliberately narrow and fails open for anything that isn't
recognizably a repo operation, so it can never break authentication:

* `github.com/<owner>/<repo>.git/...` (git smart-HTTP: clone/fetch/push), checked
* `codeload.github.com/<owner>/<repo>/...` (archive downloads), checked
* `api.github.com/repos/<owner>/<repo>/...` (repo-scoped REST calls,
  including PR creation), checked
* Anything else on those hosts (device login, OAuth token exchange, `/user`,
  `/rate_limit`, etc.), **not** checked; these aren't repo-specific and
  blocking them would break the credential flow itself

If `GITHUB_ALLOWED_REPOS` is empty/unset, this layer does nothing and PAT/App
installation scoping on GitHub's own side (`github/PROVISIONING.md`) is the
only real control, set it if you want defense-in-depth on top of that.

### ANY_HTTPS opt-in (web_fetch)

`config/allowlist.conf`'s `ANY_HTTPS` entry is a special, literal keyword (not
a hostname) recognized by `quota-guard/addons/quota_guard_addon.py`: it allows
the Gateway container to reach **any host on port 443** (HTTPS only, never
plain HTTP or other ports). It is **shipped commented out** so the platform is
strict deny-by-default out of the box; it is the one optional exception you
can deliberately enable, and it exists for exactly one reason:
`web_fetch` "always runs locally" (directly from the Gateway container, per
OpenClaw's own docs), so, unlike `web_search`, which is proxied through one
fixed provider host, there's no single fixed destination to allowlist for
"read whatever URL the agent found."

If you enable it, three things keep it from meaning "OpenClaw has free
internet access":

1. **Tool-layer gate is still the real control.** `web_fetch` is denied by
   default for every agent, including `main`
   (`config/openclaw.json5.example`). Enabling the network entry alone is
   inert: you must also remove `web_fetch` from `main`'s `tools.deny` for it
   to do anything, and `recon`/`exploit`/`reporter` still cannot call the
   tool at all. The network opening technically applies to the whole
   container (quota-guard can't attribute a proxied request to one specific
   agent), so granting `web_fetch` to any other agent gives it the exact same
   reach, narrow that, not the network entry.
2. **Shell/exec is unaffected.** Every session's `exec` still runs inside its
   own per-task sandbox container on the `clawshell-sandbox` Docker network
   (`internal: true`, zero route out), regardless of `ANY_HTTPS`. This entry
   only affects the Gateway process's own built-in tool calls.
3. **SSRF protection still applies.** quota-guard resolves every hostname,
   rejects the request if any resolved record is private/loopback/link-local,
   and pins the connection to the validated IP so DNS rebinding can't swap in
   an internal target after the check (see below), `ANY_HTTPS` cannot be used
   to reach your router, NAS, or any other host on your LAN.

Strict deny-by-default is the default. To **enable** `web_fetch`: uncomment
`ANY_HTTPS` in `config/allowlist.conf` AND remove `web_fetch` from
`agents.entries.main.tools.deny` in `config/openclaw.json5.example` (both are
required).

### Tool-level enforcement (defense in depth)

The network allowlist above is the enforcement layer, but OpenClaw's own
`web_search`/`web_fetch`/`x_search` tools (`group:web`, part of the default
`coding` tool profile) are additionally **denied outright** for `exploit` and
`reporter` via `agents.defaults.tools.deny: ["group:web"]` in
`config/openclaw.json5.example`. Without that, those two agents would still
see these tools, attempt calls, and have them fail at the network layer, wasting AI requests/iterations against your quota (see
`docs/quota-protection.md`) on calls that were never going to succeed.
Denying the tool means the model never attempts it in the first place.

`main` and `recon` both allow `web_search` only by default, denying
`web_fetch`/`x_search`. `main` is the only agent for which enabling
`web_fetch` is supported as an opt-in (see
[ANY_HTTPS opt-in](#any_https-opt-in-web_fetch) above) so it can read the full
content of a URL it found via search, not just a snippet. See
`docs/pentest-team.md#tools-what-all-four-agents-can-actually-call` for
the full per-agent config.

### DNS-rebinding / SSRF protection

quota-guard resolves each allowlisted hostname itself and pins the destination
to the resolved IP(s) for that connection rather than trusting whatever the
Gateway's own resolver returns later. Private/loopback/link-local IP ranges
are always rejected as a CONNECT target unless they exactly match your
explicit internal-service allowlist entry (which is compared against the
literal IP/host:port you configured, not a wildcard range).

## Host firewall (nftables)

See `firewall/nftables.conf` for the literal ruleset applied by
`install.sh`. Summary:

* Default policy: `drop` on `input` and `forward`; `accept` on `output`
  (the host itself is trusted; containers are constrained by Docker network
  membership + quota-guard instead of host `output` rules).
* `ct state established,related accept`
* `iifname lo accept`
* `icmp`/`icmpv6` rate-limited accept (ping, PMTUD)
* SSH (`.env: SSH_PORT`, default 22) rate-limited accept from anywhere
  (key-only auth is the real control there), or restrict to a CIDR via
  `.env: SSH_ALLOW_CIDR` if you prefer
- Control UI port (`.env: OPENCLAW_GATEWAY_PORT`, default 18789) accept only
  from `.env: LAN_ALLOW_CIDR` (defaults to RFC1918 `192.168.0.0/16`, set this
  to your actual /24 for tighter scope)
* A `DOCKER-USER`-equivalent nftables chain is installed and referenced so
  that Docker's own NAT/forwarding rules cannot silently reopen ports beyond
  what's declared in `compose/compose.yml`'s `ports:`, see the file for the
  exact chain wiring, based on the pattern documented in OpenClaw's own
  network-exposure guide for Docker + UFW/nftables interaction.

`install.sh` prints the exact ruleset it's about to apply and requires
confirmation before the first `nft -f` load; it also keeps your existing SSH
session's source IP allowed for the duration of the install so you cannot
lock yourself out mid-run.

## Exposing the Control UI outside your LAN

Not configured by default and **not recommended** by this repo. If you need
remote access, use Tailscale/WireGuard to your LAN instead of opening the
port to the internet, see OpenClaw's own
[network exposure guide](https://docs.openclaw.ai/gateway/security/network-exposure)
for the reasoning (bind modes, gateway auth requirements, reverse proxy
guidance) before doing this.

---

## See also

* [Main README](../README.md): project overview and documentation map
* [Quickstart](quickstart.md): install once, then the three ways to run a pentest
* [Architecture](architecture.md): trust boundaries, decisions, the diagram
* [GPU](gpu.md): on-box inference (NVIDIA/vLLM, AMD/ROCm), model/VRAM guidance
* [Pentest team](pentest-team.md): the 4 agents, delegation, per-agent models
* [Security](security.md): host hardening, credentials, full threat model
* [Black-box live testing](blackbox-live-testing.md): scoped egress, target-gateway, approval flow
* [Quota protection](quota-protection.md): circuit breaker, per-task limits
* [Caveman integration](caveman-integration.md): token-reduction skill and proxy
* [Credentials](credentials.md): the model-provider decision
* [Operations](operations.md): install/update/backup/restore/uninstall
* [Testing](testing.md): the regression suite (static, unit, live, manual)
* [Roadmap](roadmap.md): planned, not-yet-built work
