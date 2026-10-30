# Real Docker integration tests

Run on a disposable Linux Docker host (Docker Engine and Compose v2 with `up
--wait`, plus Python 3.11+). CI runs the suite in a separate `docker-integration`
job for pushes and PRs. No API keys, GPUs or existing ClawShell installation are
needed. Registry/package access is needed to build/pull images; test requests
only target local fixtures, never real providers or customer systems.

```bash
bash tests/run-integration.sh
bash tests/run-integration.sh --case scope
bash tests/run-integration.sh --case recovery --artifacts /tmp/clawshell-results
# Unit/static tests plus the Docker suite:
bash tests/run-all.sh --integration
```

A missing Docker executable/daemon, failed build, unhealthy service or failed
assertion exits nonzero; integration requests never turn into silent skips.
An ordinary `tests/run-all.sh` only runs static/unit tests. It never discovers
and exercises a live production deployment.

## What is real, and what is substituted

The runner renders **production Compose** into a disposable layout, checks its
network contract, and derives a uniquely named test project from it. Production
mounts, container/network names, credentials and published ports are replaced.
Production network memberships and application security settings are retained.
Only a temporary loopback UI port is published, on the actual `gateway-ui`
relay. The Gateway itself has no published ports or external bridge. Existing deployment directories
and `/opt/clawshell` are never accessed. Containers/volumes and this run's own
image tags are removed in `finally`, including on ordinary test failures.
SIGKILL or daemon/host failure can prevent cleanup; remove only resources with
the printed `clawshell-test-*` project name afterwards.

A separate `mcp-runtime` CI job tests the actual MCP server without Docker using
the image's shared dependency manifest, including real protocol/tool calls against
a local proxy fixture. Its command is `python3 tests/integration/check_mcp_runtime.py`
after installing `pentest-tools-mcp/requirements.txt`.

The actual quota-guard, target-gateway and pentest-tools MCP images are built
from their production Dockerfiles and run with their real dependencies and
entrypoints. The production fixed-destination UI relay is also run unchanged.
Before startup, a preflight loads both addons with the actual
mitmproxy script loader inside their built images. A small Python HTTP server replaces the OpenClaw process so network
and filesystem assertions do not require a model or credentials. No real
OpenClaw, nested Docker, GPU or Caveman compatibility is established by this suite.
The probe's HTTP server additionally checks host access to the published UI port;
remote LAN access and host firewall rules still require deployed-host testing.

The simulated upstream network is Docker-internal, but uses `11.203.71.0/24`
addresses, which Python classifies as global. This allows the **unchanged SSRF
checks** to accept a local positive target. Test `.test` names are mapped to these
containers. No requests are sent to public systems owning these addresses.
Docker allocates a host route for this subnet, so use a disposable host and avoid
conflicts with existing routes. Set `CLAWSHELL_TEST_UPLINK_SUBNET` to a different
globally classified IPv4 /24 if necessary. Private/documentation ranges are
intentionally rejected; using them would only test SSRF rejection, not forwarding.

## Assertions

| Case | Evidence |
| --- | --- |
| `network` | A real allowlisted response succeeds; explicit proxy denial and SSRF denial are checked; provider counters stay unchanged for denied requests. Direct Gateway/MCP connections to upstream fixtures fail, Gateway runtime networks are internal, control APIs are loopback-only, and the UI relay port remains accessible from the host while the Gateway stays internal-only. |
| `filesystem` | Engagement data can be read; even root gets EROFS when writing it or the root filesystem. Non-root report writes succeed. Docker inspect verifies capabilities, no-new-privileges, non-privileged mode, and absence of host Docker socket mounts. |
| `scope` | Allowed GET succeeds, out-of-scope/private/traversal requests fail with the exact policy reason, state-changing methods and verb tunneling need approval, approval only applies to its endpoint, target backoff suppresses forwarding, and forward/deny evidence is persisted. Actual MCP initialization, tool listing and tool calls preserve results and policy denials. |
| `killswitch` | Actual target-gateway and MCP entrypoints exit with the explicit refusal message when live testing is disabled. |
| `circuit` | Actual 401/429/503 responses open the appropriate circuit. Subsequent short-circuit responses have the correct body and upstream request counters do not increase. |
| `recovery` | Stop the actual quota-guard state writer, archive its named-volume state using the production recovery helper, mutate data, restore, verify bytes/UID/mode and component boundaries, then restart the real proxy and compare its status to the recovered snapshot. |

`recovery` exercises real volume storage, archive restore, ownership and process
reload. The updater's Git transaction, journal, crash handling, compressed backup
and full rollback scripts remain covered by the existing simulated-Docker
maintenance suite. A full install → update → failed update → rollback exercise
with actual OpenClaw on a disposable VM remains a separate release requirement.

On failure, the last 300 lines of container logs/status are also printed directly
in the CI console. Complete diagnostics are written under `<artifacts>/<project>/`: container logs, status
and structured case results. CI retains them for seven days, including failures.
The fixture contains no production credentials or engagement data.
