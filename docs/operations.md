# Operations

## Day-2 quick reference

| Task | Command |
| --- | --- |
| Update to a newer commit/image | `sudo ./scripts/update.sh [--to=<tag-or-commit>]` |
| Roll back manually | `sudo ./scripts/update.sh --rollback` |
| Back up state/config | `sudo ./scripts/backup.sh` |
| Restore | `sudo ./scripts/restore.sh backups/clawshell-<ts>.tar.zst` |
| Uninstall | `./scripts/uninstall.sh [--purge]` |
| Add an internal LAN service to the allowlist | `./scripts/allowlist.sh add <host:port>` |
| Resume after quota exhaustion | `./scripts/quota-guard.sh resume` |

Each of these is detailed below.

## Fresh install

```bash
git clone <this-repo> clawshell
cd clawshell
cp .env.example .env
$EDITOR .env          # at minimum: MODEL_PROVIDER, GITHUB_AGENT_TOKEN, LAN_ALLOW_CIDR
sudo ./scripts/install.sh
```

`install.sh` phases (each idempotent, each printed as it runs):

1. **Preflight**, checks x86_64, checks `.env` exists and
   has no placeholder values for required keys, checks it's run as root/sudo,
   checks it is not about to lock out SSH.
2. **Packages**, detects the distribution using `/etc/os-release` (`ID` and
   `ID_LIKE`), then installs dependencies with apt (Ubuntu/Debian, primary
   target), pacman (Arch/CachyOS/Manjaro), or dnf (Fedora).
   Installs Docker Engine + Compose, nftables, curl, jq, age, OpenSSL and CA
   certificates; missing NVIDIA Container Toolkit is installed and configured
   for local NVIDIA inference. Ubuntu/Debian and Fedora use Docker's official
   repository when needed; Arch uses distribution packages without a
   database-only refresh or automatic full system upgrade.
   Existing Docker installations are preserved; missing Compose is installed
   separately on apt/dnf hosts. Package failures abort installation.
   Unsupported distributions use manually installed dependencies. All paths
   check required commands and the Compose plugin before continuing.
   Apt-specific unattended-upgrades is configured only on Ubuntu/Debian;
   other hosts receive a warning to configure security updates themselves.
   See [quickstart.md](quickstart.md) for deployment limitations.
3. **System user + directories**, creates the `clawshell` system user
   (no login shell, no password) and `/opt/clawshell/{secrets,state,
   workspaces,logs,backups}` with correct ownership/permissions.
4. **Docker hardening**, writes `/etc/docker/daemon.json` (log rotation
   limits, default address pools) if not already customized; enables and
   starts the Docker service.
5. **Firewall**, renders `firewall/nftables.conf` from your `.env`
   (`SSH_PORT`, `LAN_ALLOW_CIDR`, `OPENCLAW_GATEWAY_PORT`), prints a diff
   against the running ruleset, asks for confirmation, then loads it via
   `nft -f`. Keeps a rollback copy and reverts automatically if the new
   ruleset would drop the SSH session that's running the installer.
6. **Secrets**, writes provided `.env` values into
   `/opt/clawshell/secrets/` as individual `600` files consumed by Compose
   `secrets:` (never as plaintext env in `docker inspect` output where
   avoidable); generates `OPENCLAW_GATEWAY_TOKEN` if unset.
7. **Docker networks**, creates `clawshell-egress`, `clawshell-sandbox`,
   `clawshell-control` with the topology from `docs/networking.md` (no
   `docker network create` defaults, explicit `--internal` / custom subnets
   from `compose/compose.yml`).
8. **Build/pull images**, builds `quota-guard` locally (small, deterministic
   Dockerfile) and pulls the pinned OpenClaw image tag from `.env`
   (`OPENCLAW_IMAGE`, defaults to a specific released version tag, **not**
   `latest`, for reproducibility, see `docs/architecture.md` on why floating
   tags are avoided for an always-on box).
9. **Start services**, `docker compose up -d`.
10. **Verify**, runs `scripts/healthcheck.sh --exit-code`, fails the install
    loudly if any critical check fails, and prints the Control UI URL + token
    location.
11. **systemd**, installs `systemd/clawshell.service` (wraps
    `docker compose up/down` so the stack survives reboots and is
    managed like any other host service) and
    `systemd/clawshell-healthcheck.timer` (periodic healthcheck logging).

Re-running `install.sh` after the first successful run only reconciles drift
(e.g. `.env` changes, new nftables rules), it does not recreate
`/opt/clawshell/state` or `workspaces`, and never touches existing secrets
unless you pass `--rotate-gateway-token` or similar explicit flags. Any step
that would be destructive to existing state requires `--confirm-reset`.

## Update

Run maintenance scripts as root. They require Docker Compose v2 with JSON config
output and `pull --ignore-buildable`, Python 3.11+ with `tarfile.data_filter`, jq,
zstd, tar, and flock (util-linux). Fresh apt installations include these tools;
on existing/other distributions install missing tools with the host package
manager. The updater checks prerequisites before stopping services.

```bash
sudo ./scripts/update.sh --check --to=<tag-or-commit>
sudo ./scripts/update.sh --to=<tag-or-commit>
# Without --to, use the current branch's configured upstream after fetching.
sudo ./scripts/update.sh
```

`--check` fetches metadata, verifies a fast-forward target and checks for active
`.env.example` settings missing from `.env`. It does not change the deployed Git
tree or services, and does not promise that builds or runtime checks will pass.
Existing image overrides in `.env` remain in effect: inspect them when choosing
a release. Dependency centralization/locking is separate future work.

The update rejects dirty tracked/untracked files, concurrent maintenance,
active task attribution, and task records marked RUNNING. It shares a host lock
with `pentest-task.sh`; new CLI submissions cannot race an update. An interrupted
update leaves `/opt/clawshell/maintenance-required` plus a private journal and
requires `--rollback` before another update/task. Do not submit tasks directly
through the UI/API during any maintenance window; the shell lock does not govern
those external clients. Backup/restore also take this lock.

The updater:

1. Saves the deployed commit, protected `.env`, resolved Compose config, exact
   running image references, and service activation set under
   `/opt/clawshell/deployments/<deployment-id>/`. It tags old images locally to
   retain them across pulls/builds. These snapshots can contain credentials and
   are root-private; never publish them.
2. Fast-forwards Git, validates Compose, pulls external images (including the
   on-demand CLI), and rebuilds all enabled local images with refreshed bases.
   It selects the configured NVIDIA/AMD and Caveman profiles and preserves a
   running black-box lane, without arming an inactive lane.
3. Stops all running ClawShell containers and checks persisted task attribution
   again to close the task-start race. Takes a full, verified pre-update recovery
   backup with state writers stopped.
4. Recreates selected services. Waits up to 600 seconds for running state and
   configured Docker healthchecks, probes the Gateway HTTP server and nested
   Docker daemon, and validates quota-guard's status API. Set
   `UPDATE_HEALTH_TIMEOUT` in `.env` to override the timeout, e.g. for large GPU
   models. This is readiness checking, not a model inference/security smoke test.
5. Atomically records success in `deployments/latest.json`. Any error after Git
   mutation triggers recovery and exits nonzero, even if recovery succeeds.

Updates do not run mutable upstream skill/plugin installers or silently replace
custom agent workspace files. New skills/templates need explicit review; existing
Caveman assets remain in persistent state. Host packages, GPU drivers, systemd
units, firewall changes, and schema migrations are not automatically applied.
Review release changes before deploying: this updater cannot infer whether an
upstream migration is reversible. See [Update strategy](update-strategy.md) for
remaining release/dependency work.

### Rollback

```bash
sudo ./scripts/update.sh --rollback
```

Recovery uses the pending interrupted update first, otherwise the last successful
update's pre-update snapshot. It restores the old Git commit on the current
branch, site `.env`, backed-up config/state/workspaces, and exact old locally
retained images. It recreates only previously running services with pulling and
building disabled, then verifies readiness. No registry access is needed, but the
saved images and verified archive must still exist.

Manual rollback prompts before replacing data and takes a pre-rollback safety
backup. **Rollback replaces changes made since the pre-update backup**, including
new findings and workspace edits. Automatic recovery also restores this snapshot
when available. Resolve any active task first. If recovery fails, the pending
journal remains, the command exits nonzero, and investigation is required before
resuming operation. A failed readiness check may leave containers running for
diagnostics; the maintenance marker blocks CLI task submission.

Do not prune rollback image tags, deployment directories, or archives referenced
by a deployment you may need to recover. Snapshots do not include model caches,
engagement inputs, or host package/driver versions. Models must remain compatible
with the rollback target. Recovery restores backed-up components and leaves
unlisted components intact; it does not delete a newly introduced service's data.

Installations predating UID/GID reconciliation still need a reviewed, one-time
installer reconciliation; the updater does not repair pre-existing ownership.

## Backup

```bash
sudo ./scripts/backup.sh
sudo ./scripts/backup.sh --metadata-only
sudo ./scripts/backup.sh --include-secrets
```

Backup requires an idle, running core stack. It briefly stops running ClawShell
containers for a consistent snapshot and restarts the same container IDs on
success or handled failure. The daily systemd backup timer uses the same checks;
if a pentest is running, the backup fails rather than interrupting it. Schedule
idle windows and monitor timer failures; there is no automatic deferred retry.

The version-1 manifest archive contains all existing top-level state components
except `state/local-llm`, `state/local-llm-amd` model caches and legacy
`state/update-history.json`. It also contains `config/allowlist.conf`,
`config/openclaw.json5`, `config/allowlist.d`, full workspaces, and the source Git
commit. Required core state/config/workspace paths must exist; read/copy failures
are fatal. `--metadata-only` records workspace repository commit IDs instead of
workspace contents; restoring it leaves current workspaces untouched.

`.env` and `secrets/` are excluded from the plaintext archive.
`--include-secrets` separately exports both using passphrase-encrypted age.
Application state/workspaces may themselves contain sensitive authentication or
engagement data: **all backup artifacts are private**, not safe for publication.
Keep encrypted exports and passphrases separately. Restoring `.env`/secrets is a
separate manual operation; ordinary restore does not overwrite credentials.

Archives are validated before publication, compressed with zstd and accompanied
by a SHA-256 sidecar. They live under `/opt/clawshell/backups/`, with restrictive
permissions. Verification detects corruption, not malicious replacement of both
archive and checksum. Automatic retention/pruning is disabled, including the
legacy `BACKUP_RETENTION_DAYS` setting, to preserve deployment recovery points.
Move copies off-host and manage retention explicitly. A full archive must fit on
disk alongside its uncompressed working/verification copies. Symlinks/hardlinks
escaping a backed-up component and special files are rejected rather than
silently omitted; inspect and resolve such layouts before scheduling backups.

## Restore

```bash
sudo ./scripts/restore.sh /opt/clawshell/backups/clawshell-<timestamp>.tar.zst
```

Restore verifies the supplied archive against its required checksum, validates
its manifest and archive paths/links, and shows the exact components to replace
before confirmation. These steps happen before any running service is stopped.
Only the version-1 manifest format is accepted; old unmanifested backups require
manual inspection/migration and are never applied automatically.

After confirmation, restore requires idle tasks, stops the running services and
takes a verified safety backup. It replaces only paths declared in the selected
archive, preserving numeric ownership and ordinary file/directory permissions (setuid,
setgid and sticky bits are stripped during extraction). It does not delete the
entire `state/` or `config/` tree, touch unlisted caches, or apply a blanket chown.
It recreates the previously running services using their captured images and
checks readiness. This restores data, not application code; use a compatible
ClawShell version or update rollback for coordinated code/image/data recovery.

If writing or readiness fails, the command returns nonzero, the maintenance
marker stays in place and the private journal under `/opt/clawshell/restores/`
is retained. Containers can be stopped or unhealthy. Run
`sudo ./scripts/restore.sh --recover` to apply the pre-restore safety backup and
recreate the saved service set, without pulling images. Recovery prompts before
replacing data and works with a stopped stack. A successful restore/recovery
clears its marker. A hard power loss/SIGKILL before the journal is written can
leave containers stopped; inspect and restart those containers manually.
Restore does not resume an interrupted update's journal: recover that update
with `update.sh --rollback` first.

## Uninstall

```bash
./scripts/uninstall.sh
```

Stops and removes containers/networks/images created by this repo, removes
the systemd units, and, only with `--purge`, removes
`/opt/clawshell` entirely (prompts for confirmation, offers to run
`backup.sh` first). Never touches the nftables ruleset beyond removing the
rules this repo added (keeps a pre-install snapshot for exact restoration,
written during `install.sh` step 5).

## Known limitations / follow-ups

* No externally-observed "iterations used" signal from OpenClaw itself, see
  `docs/quota-protection.md`. Revisit if OpenClaw adds a plugin/event hook for
  this.
* `MAX_CONCURRENT_TASKS > 1` attribution in quota-guard is best-effort
  (source-port/time-window based); do not raise this without reading the
  attribution notes in `docs/quota-protection.md`.
* GitHub Copilot as a direct model provider is not supported, see
  `docs/credentials.md`.

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
* [Testing](testing.md): the regression suite (static, unit, live, manual)
* [Roadmap](roadmap.md): planned, not-yet-built work
