# Update strategy

Status: release/dependency design with an initial recovery implementation.
Backup/restore and the current updater now implement verified component backups,
image/config snapshots, locking, readiness checks and automatic recovery. Explicit
release manifests, staged release activation, dependency locking and schema
migrations remain future work. See [Operations](operations.md#update) for the
implemented interface and limits.

## Scope and ownership

An update must distinguish three layers:

| Layer | Contents | Update owner |
| --- | --- | --- |
| ClawShell release | Scripts, Compose, agent templates, config schema, migrations | Versioned ClawShell release |
| Application dependencies | OpenClaw, inference servers, DinD, four local images, Python/npm dependencies, Caveman skill and downloaded binaries | Reviewed dependency changes included in a release |
| Host | OS, Docker Engine/Compose, systemd, nftables, GPU drivers/runtime | Distribution package manager, separate maintenance window |

Model weights are managed artifacts: record the model identifier and immutable
revision/digest where available. Downloading a new model is explicit, with disk
and GPU capacity checks; it must not happen implicitly during a platform update.

Host changes stay separate because container rollback cannot undo a Docker,
kernel, or GPU-driver upgrade. Document supported host versions for each release
and verify them before deployment. Never run a generic package upgrade from the
platform updater; Arch updates in particular need a full system upgrade rather
than a package-database-only refresh.

## Dependency inventory and reproducibility

The release must supply one machine-readable manifest with the release version,
config/data schema versions, image digests, dependency lockfile checksums, skill
source commits, and any required migrations. Keep editable site settings and
credentials in `.env`; keep release dependency versions in version-controlled
files. Explicit operator image overrides must be shown in the update plan and
recorded in deployment history.

Current sources that must be covered:

| Source | Current gap | Target |
| --- | --- | --- |
| Compose and `.env.example` | Duplicated versions; local `.env` retains old pins; ROCm and DinD tags can move | Release image digests plus explicit overrides |
| Python Dockerfiles | `mitmproxy==11.*`, `httpx==0.27.*`; no transitive lock | Exact, hashed dependency locks per application image |
| Docker base images | Python/Node tags can move | Version and digest pins, refreshed deliberately |
| Caveman proxy | CLI version fixed, setup downloads separate binaries | Record and verify CLI, proxy, engine versions/checksums |
| Caveman skill | Installs from GitHub without a commit pin; failure swallowed | Commit pin, artifact checksum, observable install result |
| CI actions and test packages | Action tags; unpinned test `httpx` | Action commit pins and locked test dependencies |

Dependency automation should open reviewable PRs for these sources, never deploy
them directly. Group compatible changes by component; keep major upgrades and
GPU runtime changes separate. Run checks for every PR, review routine updates
weekly, and prioritize security fixes. A release records the tested combination;
an individual deployment should not independently resolve newest versions.

## Intended operator interface

These commands are proposed, not currently available:

```bash
sudo ./scripts/update.sh --check --to <release>
sudo ./scripts/update.sh --to <release>
sudo ./scripts/update.sh --rollback <deployment-id>
```

`--check` reports the current/target release, effective dependencies, migrations,
new settings, estimated downtime, and rollback constraints without changing the
deployed checkout or running stack. Fetching release metadata is allowed.

Updates target an explicit published release. Do not advance the deployment with
an implicit `git pull` on an arbitrary branch. Reject concurrent updates with a
host lock, dirty tracked files, missing prerequisites, incompatible hosts, and
active pentest tasks. Block new tasks for the maintenance window and coordinate
with scheduled backup/service operations. Do not use `--force` to bypass these
conditions.

## Deployment transaction

1. Resolve the release into a separate staging directory. Validate its source,
   manifest, config schema, and required host capabilities before activation.
2. Render Compose with the site's actual configuration. Select only enabled
   profiles: core, selected GPU backend, optional Caveman, optional black-box
   services. Include the on-demand CLI image without starting its service.
3. Pull external images by digest and build all selected local images, not just
   quota-guard. Install pinned skill artifacts in staging. Validate configuration
   and migration prerequisites while the old deployment remains available.
4. Enter maintenance, drain tasks, and make a consistent recovery backup while
   state writers are stopped. Capture local configuration, agent workspaces,
   relevant persistent state, permissions, deployed commit, effective image IDs,
   and profile selection. Store credentials only in a protected/encrypted
   recovery artifact, never logs or a public manifest. Verify backup integrity;
   abort on errors. Model caches may be referenced by digest rather than copied.
5. Keep the old release and pin/tag its images for recovery. Persist a journal
   with a deployment ID and status before mutations. Record each completed step
   atomically so interruption can be detected on the next invocation.
6. Apply versioned, idempotent migrations. New optional settings use documented
   defaults; missing required settings stop before activation. Never replace
   `.env` wholesale or overwrite operator-customized agent files silently.
7. Activate the staged release and start its selected services. Apply explicit
   systemd/firewall migrations only with validated recovery steps. Replacing
   containers must not silently grant additional network access.
8. Poll readiness with a bounded timeout. Check core APIs and enabled services,
   including selected inference, Caveman, and black-box profiles. Verify the
   intended security boundaries and a non-destructive task smoke test. Do not
   equate a container being `running` with its application being ready.
9. Commit the successful deployment to history and leave maintenance. Retain at
   least the previous known-good release, image references, and recovery backup.
   Garbage collection is a separate explicit operation.

Any failure after mutation enters recovery, including build/start/migration
failures and interrupted deployments, not only a final healthcheck failure.
Before mutation, failure simply discards staging and leaves deployment intact.

## Recovery contract

Restore the previous release's actual image IDs and configuration/profile set;
never resolve a floating tag again during rollback. Recreate containers without
pulling or rebuilding and verify health. A failed update exits nonzero even if
automatic recovery succeeds; a failed manual rollback also exits nonzero.

Container rollback and data rollback are distinct. Schema-changing releases must
declare whether old code can read the new data. Restore a consistent state backup
only under an explicit recovery policy, with services stopped: otherwise new
findings or workspace edits could be lost. An irreversible migration requires a
reviewable restore plan before deployment. Never promise universal automatic
rollback across arbitrary upstream schema changes.

Backup/restore now reject checksum and source-read failures, preserve ownership,
and restore only manifest-declared components. The updater keeps protected site
configuration, resolved Compose files and locally retained image references.
These paths still need real-host recovery exercises for each supported profile.

## Delivery order and required evidence

1. Harden backup/restore and implement deployment snapshots plus image recovery.
   Test corrupted archives, missing state, and recovery without registry access.
2. Implement staged release selection, locking, journal, maintenance/task drain,
   configuration validation, profile-aware builds, and bounded readiness checks.
   Mock tests must cover every failure boundary, interruption, dirty checkouts,
   missing settings, overrides, and manual rollback exit status.
3. Centralize dependency versions, add transitive locks and pinned skills/binaries,
   and configure dependency PR automation. Ensure installer and updater consume
   the same release manifest; put regression tests in the CI test runner.
4. Add release CI: regression checks, image builds, dependency vulnerability
   review, SBOM/artifact provenance, and release notes with migration/compatibility
   information. Verify install → update → rollback in a disposable deployed host.
5. Exercise hosted-provider, NVIDIA, AMD, Caveman, and black-box configurations.
   Hardware-dependent paths require their corresponding test hosts; publish
   untested combinations rather than implying they passed ordinary unit CI.

The mocked recovery suite covers update and rollback failure paths. Full release
transactions and compatibility across upstream data migrations must not be
advertised until their deployed-host recovery tests pass.
