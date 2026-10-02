# Testing / regression checks

ClawShell ships a self-contained regression suite. Everything that does not
require a deployed host runs on a plain dev laptop (or CI) with no root, no
containers, and no network.

```bash
./tests/run-all.sh
```

Run an individual file directly for faster iteration, e.g.:

```bash
./tests/test-static-validation.sh
./tests/test-python-unit.sh
```

## What runs where

`run-all.sh` groups the tests into three tiers.

### Static / unit (always run, no deployed host)

These are safe anywhere and gate every change:

| Test | What it proves |
| --- | --- |
| `test-static-validation.sh` | Shell syntax across `scripts/`, `caveman-proxy/`, `tests/`; `install.sh` phase numbering is sequential; every `.env.example` var is referenced somewhere; allowlist defaults are consistent; secrets-hygiene (nothing gitignored is tracked); `docker compose config` validates with placeholder secrets. |
| `test-credential-provider-logic.sh` | The model-provider credential decision logic (which provider needs which key). |
| `test-github-repo-scope-logic.sh` | `GITHUB_ALLOWED_REPOS` parsing / repo-scope enforcement logic. |
| `test-blackbox-killswitch.sh` | The black-box live-testing kill switch is enforced in depth: the `target-gateway` entrypoint refuses to start unless `BLACKBOX_LIVE_TESTING=true` (so a direct `docker compose --profile blackbox-live up` cannot arm it), the guard precedes `exec mitmdump`, upstream TLS verification is asserted (`ssl_insecure=false`), the launcher gates `--live`, and the `disarm_live` EXIT/INT/TERM trap is installed. |
| `test-python-unit.sh` | The Python unit suite under `tests/unit/` (see below). |

### Python unit suite (`tests/unit/`)

Run by `test-python-unit.sh` via `python3 -m unittest discover`. The heavy
runtime deps (`mitmproxy`, `mcp`) are stubbed, DNS and HTTP are faked, and all
state is redirected to temp dirs, so these are true units: no Docker, no
network, no deployed host.

| Module | Coverage |
| --- | --- |
| `test_target_gateway_addon.py` | The `target-gateway` decision logic and the full `request()`/`response()` lifecycle: deny-by-default scope, encoded-traversal rejection (`%2e%2e`/`%2f`), SSRF / internal-address blocking (loopback, link-local incl. cloud metadata, RFC1918; `localhost` scope refused), effective-method gating (a method-override header cannot smuggle a `DELETE` past a Tier-0 `GET`), full-path approval descriptors (one approval does not cover sibling endpoints), rate limiting, fail-closed state parsing, and denied-flow evidence-log integrity. |
| `test_control_api.py` | The loopback control API (state helpers + the HTTP handler over an in-process server): engagement start/stop, approve/revoke, status + scope summary, and fail-closed handling of bad JSON / unknown routes. |
| `test_pentest_tools_mcp.py` | The pentest-tools MCP server: gateway-decision parsing (`blocked_by` -> `gateway_decision` / `action_needed`), body truncation, technology fingerprint markers, and the kill switch (the `__main__` guard refuses to start unless `BLACKBOX_LIVE_TESTING=true`). |
| `_stubs.py` | Shared `mitmproxy` / `mcp` stubs so the suite runs where those packages are absent. |

### Live-host (auto-run only if a deployment is detected)

If `run-all.sh` sees a running `clawshell-openclaw-gateway` container it also
runs the isolation / circuit-breaker tests against it; otherwise they are
reported as skipped.

| Test | What it proves |
| --- | --- |
| `test-filesystem-isolation.sh` | The engagement mount is read-only and the agent cannot escape its workspace. |
| `test-network-isolation.sh` | Egress is deny-by-default; out-of-allowlist hosts are blocked. |
| `test-quota-guard-circuit-breaker.sh` | The AI-spend circuit breaker opens on simulated quota exhaustion and short-circuits further requests. |

### Manual / outline

| Test | Notes |
| --- | --- |
| `test-task-runtime-limit.sh` | Documented manual steps to confirm a task is hard-stopped at its runtime cap; not auto-run. |

## Adding a test

- Shell tests live in `tests/*.sh`; register them in the appropriate array in
  `tests/run-all.sh` (`STATIC_TESTS`, `LIVE_TESTS`, or `MANUAL_TESTS`).
- Python unit tests live in `tests/unit/test_*.py` and are discovered
  automatically by `test-python-unit.sh`; reuse `tests/unit/_stubs.py` to avoid
  importing heavy service dependencies.

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
* [Caveman integration](caveman-integration.md): token-reduction skill and proxy
* [Credentials](credentials.md): the model-provider decision
* [Operations](operations.md): install/update/backup/restore/uninstall
* [Roadmap](roadmap.md): planned, not-yet-built work
