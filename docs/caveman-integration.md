# Caveman integration

[Caveman](https://github.com/JuliusBrussee/caveman) is a real, independently
maintained, MIT+BSL-1.1 open-source project (verified against the live repo, 105k+ stars, active releases) that reduces AI token spend two ways: a **skill**
(rule file that makes agent replies terser, output tokens) and a **local
proxy** (compresses what the agent reads before it's sent upstream, input
tokens). It explicitly documents support for wrapping OpenClaw. This directly
complements quota-guard: quota-guard is the safety backstop (circuit breaker,
allowlist, hard per-task ceilings); caveman reduces how much of your quota a
*well-behaved* task actually consumes in the first place. Neither replaces
the other.

## What's enabled by default: the skill

`CAVEMAN_SKILL_ENABLED=true` (default). `scripts/install-caveman-skill.sh`
runs the upstream-documented install for OpenClaw, `npx -y github:JuliusBrussee/caveman -- --only openclaw`, which drops a
skill folder and a `SOUL.md` marker block into OpenClaw's workspace
(`state/openclaw/workspace/`). This is a **text rule file**, not a proxy or
daemon: it changes nothing about network topology, containers, or attack
surface. It's called from `install.sh`/`update.sh` on the host, once, against
the `openclaw-cli` container.

Because this is the only step in the whole system that needs npm/GitHub
package-resolution egress, it gets a **temporary** allowlist entry
(`config/allowlist.d/zz-temp-caveman-install.conf`) written immediately
before the install and deleted immediately after, the always-on Gateway's
runtime allowlist is never widened for this.

## The proxy (input-token compression)

`CAVEMAN_PROXY_ENABLED=false` by default, gated behind Compose's
`caveman-proxy` profile. Unlike the earlier draft of this doc, this is now a
**verified, working integration**, not a placeholder.

### How it actually works

Upstream's `docs/technical/cli-reference.md` and `docs/technical/proxy-and-providers.md`
document a genuinely standalone daemon command, independent of "wrap an
agent's launch":

```bash
caveman start   # loopback HTTP proxy, default 127.0.0.1:8787
```

It exposes provider-compatible routes (`/anthropic/...`, `/openai/...`,
`/compat/<name>/...`) and forwards to the real provider with your credentials
passed through untouched, while compressing large payloads (logs, diffs,
JSON, search results) in both directions with a local, byte-exact recovery
cache.

**One important, verified constraint: the proxy refuses to bind any
non-loopback address.** A plain sidecar container on its own Docker network
would be unreachable, 127.0.0.1 inside one container isn't 127.0.0.1 inside
another. So `caveman-proxy` uses
`network_mode: "service:openclaw-gateway"` in `compose/compose.yml`: it joins
the Gateway's network namespace, making the Gateway's loopback and
caveman-proxy's loopback the *same* interface. This is the same pattern
already used for `openclaw-cli`.

```
openclaw-gateway  --(loopback swap, MODEL_PROVIDER_BASE_URL)-->  caveman-proxy
                                                                       |
                                                          (HTTP_PROXY, real egress)
                                                                       v
                                                                  quota-guard
                                                                       |
                                                                       v
                                                              real upstream provider
```

quota-guard is untouched as the enforcement point: it's caveman-proxy, not
openclaw-gateway, that dials out through it, and it still sees (and can
allowlist-check / circuit-break on) every real request to the real provider
host, just fewer bytes, since caveman already compressed them.

### Scope: MODEL_PROVIDER=custom only (today)

Caveman's `compat` mount mechanism is documented for OpenAI-compatible
upstreams. This repo's existing `MODEL_PROVIDER=custom` path (see
`docs/credentials.md`) already assumes an OpenAI-compatible wire protocol, so wiring caveman-proxy in front of it reuses an assumption we'd already
made, rather than a new one.

We deliberately do **not** (yet) claim proxy support for the official
`MODEL_PROVIDER=anthropic`/`openai` plugins or for the default
`MODEL_PROVIDER=github-copilot`:

* For `anthropic`/`openai`: OpenClaw's `models.providers.<id>.baseUrl` config
  key *is* confirmed (per `docs.openclaw.ai/concepts/model-providers/custom-providers`)
  to be able to override a bundled official provider's base URL, which would
  in principle let you point it at caveman-proxy's native `/anthropic` or
  `/openai` routes without the `compat` upstream-secret duplication this repo
  currently ships. This has **not** been implemented or tested in this repo
  yet, it's a real, plausible improvement, just not one we've verified
  end-to-end. Treat it as a documented future-work item, not a supported
  path today.
* For `github-copilot` (the default provider in this repo): caveman-proxy's
  request/response passthrough has not been verified against the Copilot
  API's token-exchange and request-identity headers at all. Until that's
  explicitly tested, assume it does not work.

If you're on `anthropic`/`openai` today and want the proxy as it currently
ships, switch to `MODEL_PROVIDER=custom` pointed at an OpenAI-compatible
endpoint for your provider (if one exists), a real trade-off, not a bug in
this repo.

### Enabling it


```bash
# 1. Note your REAL current upstream endpoint, then in .env:
CAVEMAN_UPSTREAM_BASE_URL=<what MODEL_PROVIDER_BASE_URL currently is>
MODEL_PROVIDER_BASE_URL=http://127.0.0.1:8787/compat/upstream
CAVEMAN_PROXY_ENABLED=true

# 2. Start the sidecar (profile-gated, not started by a plain `up -d`):
docker compose -f compose/compose.yml --profile caveman-proxy up -d caveman-proxy

# 3. Restart the Gateway so it picks up the new MODEL_PROVIDER_BASE_URL:
docker compose -f compose/compose.yml restart openclaw-gateway

# 4. Verify:
docker compose -f compose/compose.yml logs caveman-proxy   # "starting, upstream=..."
./scripts/healthcheck.sh
```

The same `model_provider_api_key` secret is reused, `caveman-proxy`'s
entrypoint reads it and exports it under the `CAVEMAN_UPSTREAM_API_KEY` name
that its generated `caveman.yaml` compat mount references. No credential
duplication, no new secret file.

### Verified locally

Built the `caveman-proxy` image and end-to-end tested it standalone (fake API
key, real upstream host): the container starts, generates `caveman.yaml`,
binds `127.0.0.1:8787`, and forwarding actually reaches the real provider, confirmed by getting back a genuine `401 Unauthorized` from `api.openai.com`
through `/compat/upstream/v1/chat/completions` (not a local error), proving
the whole chain (entrypoint → credential injection → compat mount →
real network egress) works. One benign warning appears in logs on some hosts:
`native runtime unavailable; hooks remain fail-open`, upstream documents
this path as fail-open (proxy keeps running, just without an optional native
hook), and it did not prevent the proxy from serving requests correctly.

### Disabling / rollback

Set `CAVEMAN_PROXY_ENABLED=false`, restore `MODEL_PROVIDER_BASE_URL` to the
real upstream value, restart `openclaw-gateway`, and
`docker compose -f compose/compose.yml --profile caveman-proxy stop caveman-proxy`.
Nothing about the Gateway's own config or credentials was touched, so this is
a clean revert.


## License

BSL-1.1 covers the Engine/Proxy/rewriter. Per upstream's own license section:
*"Read it, fork it, self-host it for your own first-party traffic free,
production included."*, this is exactly our use case (self-hosted, one
household, first-party traffic only), so no commercial license is required.
The skill itself, the CLI, and the installer are plain MIT. Re-check the
`LICENSE`/`LICENSE-BSL` files in the caveman repo if you materially change how
it's used (e.g. hosting it for anyone outside your own household).

## Telemetry

Caveman's CLI sends anonymous, content-free usage telemetry
(`https://api.caveman.so/telemetry/cli`) **on by default**. This repo forces
it off everywhere caveman is invoked (`DO_NOT_TRACK=1`, `CAVEMAN_TELEMETRY=0`
in `install-caveman-skill.sh` and, if you enable it, should also be set on the
`caveman-proxy` service), consistent with this repo's deny-by-default
network posture. `api.caveman.so` is **not** in the runtime egress allowlist;
if telemetry fires anyway despite the env vars, quota-guard blocks it and
logs it (upstream's own docs confirm telemetry failures never fail the CLI
command, so this fails safe).

## Local data

`state/caveman/` (mounted to `/home/caveman/.caveman` in the `caveman-proxy`
container) holds the generated `caveman.yaml` and the local recovery cache
(`caveman.db`), per-request metadata and recoverable originals of
compressed payloads, potentially sensitive (logs, diffs, code). It's created
automatically the first time `caveman-proxy` starts, and covered by
`.gitignore`'s `state/` rule like every other persistent volume in this repo.
If you enable the proxy, add `state/caveman` to `scripts/backup.sh` /
`docs/operations.md` alongside `state/openclaw`, not included by default
since the proxy itself is off by default.

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
* [Quota protection](quota-protection.md): circuit breaker, per-task limits
* [Credentials](credentials.md): the model-provider decision
* [Operations](operations.md): install/update/backup/restore/uninstall
* [Testing](testing.md): the regression suite (static, unit, live, manual)
* [Roadmap](roadmap.md): planned, not-yet-built work
