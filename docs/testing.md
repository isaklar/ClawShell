# Testing / regression checks

ClawShell ships a self-contained regression suite. Everything that does not
require a deployed host runs on a plain dev laptop (or CI) with no root, no
containers, and no external network. The API tests use a loopback HTTP server.
Install `httpx` in your test Python environment and provide `git`, `jq`, `zstd`,
and `flock` for the maintenance integration tests (CI installs these tools).

```bash
./tests/run-all.sh
```

Run an individual file directly for faster iteration, e.g.:

```bash
./tests/test-static-validation.sh
./tests/test-python-unit.sh
```

## What runs where

`run-all.sh` runs static/unit tests by default. Add `--integration` to also run
the isolated Docker stack; it never probes an existing installation automatically.

### Static / unit (always run, no deployed host)

These are safe anywhere and gate every change:

| Test | What it proves |
| --- | --- |
| `test-static-validation.sh` | Shell syntax across `scripts/`, `caveman-proxy/`, `tests/`; `install.sh` phase numbering is sequential; every `.env.example` var is referenced somewhere; allowlist defaults are consistent; secrets-hygiene (nothing gitignored is tracked); `docker compose config` validates with placeholder secrets. |
| `test-credential-provider-logic.sh` | The model-provider credential decision logic (which provider needs which key). |
| `test-install-packages.sh` | Installer package phase with mocked host tools: Ubuntu/Debian apt, Arch/CachyOS/Manjaro pacman, Fedora dnf, derivative detection, Docker/Compose installation, NVIDIA toolkit configuration, manual fallback, post-install checks, fatal package/restart errors, and apt-only unattended-upgrades. Does not prove a full deployment works on every distribution. |
| `test-github-repo-scope-logic.sh` | `GITHUB_ALLOWED_REPOS` parsing / repo-scope enforcement logic. |
| `test-blackbox-killswitch.sh` | The black-box live-testing kill switch is enforced in depth: the `target-gateway` entrypoint refuses to start unless `BLACKBOX_LIVE_TESTING=true` (so a direct `docker compose --profile blackbox-live up` cannot arm it), the guard precedes `exec mitmdump`, upstream TLS verification is asserted (`ssl_insecure=false`), the launcher gates `--live`, and the `disarm_live` EXIT/INT/TERM trap is installed. |
| `test-python-unit.sh` | The Python unit suite under `tests/unit/` (see below). |

### Python unit suite (`tests/unit/`)

Run by `test-python-unit.sh` via `python3 -m unittest discover`. The heavy
runtime deps (`mitmproxy`, `mcp`) are stubbed, DNS and HTTP are faked, and all
state is redirected to temp dirs, so these are true units: no Docker, no
external network, no deployed host. Loopback sockets must be permitted for the
control API tests. Maintenance tests run the real shell scripts against temporary
Git repositories and a simulated Docker executable; all host paths and root checks
are redirected only in those disposable fixture copies.

| Module | Coverage |
| --- | --- |
| `test_addon_script_loading.py` | Both proxy addons load under mitmproxy 11's unregistered-module script-loading behavior; catches dataclass/string-annotation startup failures hidden by ordinary imports. |
| `test_integration_diagnostics.py` | Failed integration runs retain complete artifacts and print bounded container logs/status directly in CI. |
| `test_target_gateway_addon.py` | The `target-gateway` decision logic and the full `request()`/`response()` lifecycle: deny-by-default scope, encoded-traversal rejection (`%2e%2e`/`%2f`), SSRF / internal-address blocking (loopback, link-local incl. cloud metadata, RFC1918; `localhost` scope refused), effective-method gating (a method-override header cannot smuggle a `DELETE` past a Tier-0 `GET`), full-path approval descriptors (one approval does not cover sibling endpoints), rate limiting, fail-closed state parsing, and denied-flow evidence-log integrity. |
| `test_control_api.py` | The loopback control API (state helpers + the HTTP handler over an in-process server): engagement start/stop, approve/revoke, status + scope summary, and fail-closed handling of bad JSON / unknown routes. |
| `test_pentest_tools_mcp.py` | The pentest-tools MCP server: gateway-decision parsing (`blocked_by` -> `gateway_decision` / `action_needed`), body truncation, technology fingerprint markers, and the kill switch (the `__main__` guard refuses to start unless `BLACKBOX_LIVE_TESTING=true`). |
| `test_recovery.py` | Manifest archive roundtrips, ownership/modes, component boundaries, corruption/path/link/special-file rejection, image snapshots and readiness checks. |
| `test_maintenance.py` | Actual backup/update/restore scripts with isolated Git and simulated Docker: failed pulls/builds/start/readiness, locks, active tasks, interrupted recovery, selected profiles, offline rollback and restore safety-backup recovery. |
| `test_integration_fixture.py` | Fixture construction preserves production boundaries and rejects external control networks, exposed proxy ports, existing external networks and private simulated-upstream subnets. |
| `test_integration_probe.py` | Real loopback HTTP responses/counters, propagation of connection failures, and MCP session/SSE client handling used by integration probes. |
| `test_static_validation_safety.py` | Compose validation leaves existing state/secrets/workspace symlinks and their contents intact. |
| `_stubs.py` | Shared `mitmproxy` / `mcp` stubs so the suite runs where those packages are absent. |

### Real Docker integration (separate CI job)

```bash
bash tests/run-integration.sh
bash tests/run-all.sh --integration
```

The `docker-integration` CI job builds and runs actual quota-guard, target-gateway
and MCP images in a uniquely named disposable project. It verifies successful
forwarding alongside exact policy denials, circuit opening and upstream request
counts, approval/scope/backoff enforcement, the actual MCP HTTP transport,
read-only mounts and report writes, runtime network boundaries, kill switches,
and archive recovery of actual persistent proxy state followed by process restart.
Diagnostics are uploaded even when tests fail. Consider making this check required
in repository branch protection alongside the existing `test` check.

The historical `test-network-isolation.sh`, `test-filesystem-isolation.sh` and
`test-quota-guard-circuit-breaker.sh` now invoke individual cases of this isolated
suite. They never alter a live installation. The old blanket "anything except
HTTP 200 means blocked" checks and unconditional circuit-breaker success have
been removed.

Docker is required when integration is requested: missing prerequisites fail
rather than skip. The OpenClaw process is replaced with a small HTTP/probe
fixture; actual OpenClaw, GPU, nested Docker and full installation/update
compatibility are **not** asserted. See the [integration guide](../tests/integration/README.md)
for the fixture subnet, safety boundaries, commands, coverage and remaining gaps.

### Manual / outline

| Test | Notes |
| --- | --- |
| `test-task-runtime-limit.sh` | Documented manual steps to confirm a task is hard-stopped at its runtime cap; not auto-run. |

## Maintenance release validation

Mocked Docker tests cannot establish compatibility with real images or GPU
hardware. Before shipping an updater release, exercise fresh install → update →
failed readiness → rollback and backup → restore → restore recovery on a disposable
host. Verify preserved data/ownership, selected profiles, retained images with the
registry unavailable, interrupted deployment journals, and task lock behavior.
Run hosted-provider, AMD/NVIDIA, Caveman and black-box profiles on corresponding
hosts. Never use the first recovery exercise against irreplaceable engagement data.

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
