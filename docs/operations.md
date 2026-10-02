# Operations

## Day-2 quick reference

| Task | Command |
| --- | --- |
| Update to a newer commit/image | `./scripts/update.sh` (auto rollback on failed healthcheck) |
| Roll back manually | `./scripts/update.sh --rollback` |
| Back up state/config | `./scripts/backup.sh` |
| Restore | `./scripts/restore.sh backups/clawshell-<ts>.tar.zst` |
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

1. **Preflight**, checks for a Debian/Ubuntu-family package manager (apt) and
   x86_64, checks `.env` exists and
   has no placeholder values for required keys, checks it's run as root/sudo,
   checks it is not about to lock out SSH.
2. **Packages**, installs Docker Engine + Compose plugin (official Docker
   apt repo, pinned to the distro codename), nftables, unattended-upgrades,
   curl, jq, age.
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

```bash
./scripts/update.sh
```

1. `git fetch && git status`, refuses to proceed on a dirty working tree or
   if you're not on the branch you deployed from (override with `--force`).
2. `git pull --ff-only` (fast-forward only, a merge conflict here means "go
   look at this manually," not "improvise").
3. Diffs `compose/compose.yml` and `.env.example` against your local `.env`
   for new required keys; stops and tells you exactly what to add if any are
   missing (never silently defaults a security-relevant new key).
4. `docker compose pull` (pinned tags, this is a deliberate version bump you
   control by changing `OPENCLAW_IMAGE`/`QUOTA_GUARD_TAG` in `.env`, not an
   implicit `latest` float).
5. `docker compose build quota-guard` (rebuilds only if the Dockerfile/addon
   changed).
6. Snapshots current container images (`docker compose images -q`) as the
   rollback target before recreating anything.
7. `docker compose up -d` (recreates only changed services).
8. `scripts/healthcheck.sh --exit-code`, if it fails, `update.sh` **automatically
   rolls back**: re-tags the previous images as `:current` and
   `docker compose up -d` again, then exits non-zero so you know an update was
   attempted and reverted.
9. Persistent data (`/opt/clawshell/state`, `workspaces`) is never touched
   by update, only images/containers are replaced. Secrets are never
   rewritten by `update.sh`.

> **One-time note for installs predating `AGENT_UID`/`AGENT_GID`:** if you
> deployed before ownership of `state/quota-guard`/`state/sandbox-dind`/the
> Gateway containers' UID was reconciled automatically, `update.sh` alone
> won't fix existing file ownership, it only replaces images/containers,
> never touches permissions on host directories. Run `sudo ./scripts/install.sh`
> once after updating (idempotent and safe to re-run) to pick up the correct
> `AGENT_UID`/`AGENT_GID` and re-chown the quota-guard/sandbox-dind state
> dirs to their required fixed UIDs.

### Rollback strategy

* Automatic, as above, on a failed post-update health check.
* Manual: `./scripts/update.sh --rollback` re-applies the last snapshot
  recorded in `state/update-history.json` (image digests + git commit at time
  of last successful update).
* Git-level rollback: `git checkout <previous-tag-or-commit>` then re-run
  `./scripts/update.sh`, this repo's own history is your configuration
  rollback path, which is why `install.sh`/`update.sh` never hand-edit files
  outside `.env`/`config/allowlist.d/` (both git-ignored, both backed up by
  `backup.sh`).

## Backup

```bash
./scripts/backup.sh
```

Archives (tar + zstd) `state/openclaw`, `state/quota-guard`, `config/`
(excluding secrets), and full `workspaces/` working trees by default (pass
`--metadata-only` for the lighter git-remote/branch-only capture instead,
if you've verified where delegated-session clones land and want
smaller/faster backups) into `backups/clawshell-<timestamp>.tar.zst`,
plus a checksum file. Secrets are **never** included in this archive; back
those up separately/manually via your own password manager or
`age`-encrypted export (`./scripts/backup.sh --include-secrets` produces a
separate `age`-encrypted file if you explicitly opt in, requiring a
passphrase prompt).

Runs automatically once a day via the `clawshell-backup.timer` systemd
unit (installed and enabled by `install.sh`; see `systemd/clawshell-backup.timer`
for the schedule). Run `./scripts/backup.sh` manually any time for an
on-demand backup, e.g. right before `./scripts/update.sh`.

## Restore

```bash
./scripts/restore.sh backups/clawshell-<timestamp>.tar.zst
```

Stops services, verifies the checksum, extracts into a temp dir, diffs
against current `state/`/`config/` (prints what would change), asks for
confirmation, then swaps in. Restarts services and runs `healthcheck.sh`
automatically at the end.

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
