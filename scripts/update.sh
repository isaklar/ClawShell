#!/usr/bin/env bash
# Update a clean deployment with offline image/config/data recovery.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
source scripts/lib/maintenance.sh
require_root
umask 077
TARGET=
ROLLBACK=0
CHECK=0
for arg in "$@"; do
  case "${arg}" in
    --rollback) ROLLBACK=1 ;;
    --check) CHECK=1 ;;
    --to=*) TARGET="${arg#--to=}" ;;
    --force) die "--force is no longer supported: commit/stash tracked changes before maintenance." ;;
    *) die "Usage: $0 [--check] [--to=<tag-or-commit>] | --rollback" ;;
  esac
done
(( ! ROLLBACK || (! CHECK && ${#TARGET} == 0) )) || die "--rollback cannot be combined with --check/--to."
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "Working tree is dirty. Commit/stash changes first."
maintenance_require
maintenance_lock
[[ ! -f /opt/clawshell/restores/pending.json ]] || die "An interrupted restore needs restore.sh --recover first."
mkdir -p "${DEPLOYMENTS_DIR}"
chmod 700 "${DEPLOYMENTS_DIR}"
HISTORY_FILE="${DEPLOYMENTS_DIR}/latest.json"
PENDING_FILE="${DEPLOYMENTS_DIR}/pending.json"
MAINTENANCE_HELPER="${REPO_ROOT}/scripts/lib/recovery.py"
STOPPED_CONTAINERS=()
BACKUP_WORKDIR=
SNAPSHOT=
MUTATED=0
QUIESCED=0

journal() {
  local status="$1"
  jq -n --arg snapshot "${SNAPSHOT}" --arg status "${status}" \
    '{snapshot: $snapshot, status: $status}' > "${PENDING_FILE}.tmp" || return 1
  mv "${PENDING_FILE}.tmp" "${PENDING_FILE}"
}

recover() {
  local previous archive config
  previous="$(cat "${SNAPSHOT}/commit")"
  config="${SNAPSHOT}/rollback.json"
  local old_services
  old_services="$(jq -er '.[]' "${SNAPSHOT}/services.json")" || return 1
  mapfile -t OLD_SERVICES <<<"${old_services}"
  # Use direct container labels: even a broken candidate Compose file must
  # not prevent stopping all its state writers before recovery.
  local running
  running="$(docker ps -q --filter label=com.docker.compose.project=clawshell)" || return 1
  if [[ -n "${running}" ]]; then
    # Docker IDs contain no whitespace other than the separating newlines.
    docker stop ${running//$'\n'/ } >/dev/null || return 1
  fi
  git reset --keep "${previous}" || return 1
  cp -a "${SNAPSHOT}/site.env" "${ENV_FILE}" || return 1
  if [[ -f "${SNAPSHOT}/backup" ]]; then
    archive="$(cat "${SNAPSHOT}/backup")"
    local extraction
    extraction="$(mktemp -d "${SNAPSHOT}/restore-XXXXXXXX")" || return 1
    # Invoke in a subshell: die must not skip the caller's recovery result.
    (maintenance_verify_archive "${archive}" "${extraction}") || return 1
    python3 "${SNAPSHOT}/recovery.py" restore "${extraction}/contents" "${REPO_ROOT}" /opt/clawshell || return 1
    rm -rf "${extraction}"
  fi
  docker compose --project-directory "${REPO_ROOT}/compose" -f "${config}" \
    up -d --force-recreate --pull never --no-build "${OLD_SERVICES[@]}" || return 1
  STOPPED_CONTAINERS=()
  maintenance_wait "${config}" "${OLD_SERVICES[@]}" || return 1
  journal recovered || return 1
  rm -f "${PENDING_FILE}" /opt/clawshell/maintenance-required
  info "Previous commit, images and configuration recovered."
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( rc != 0 && MUTATED )); then
    err "Update failed; recovering the previous deployment."
    if ! recover; then
      err "RECOVERY FAILED. Keep maintenance in effect; use --rollback after investigating ${SNAPSHOT}."
    fi
  elif (( rc != 0 && QUIESCED )); then
    maintenance_resume || err "Failed to restart stopped services."
  fi
  [[ -z "${BACKUP_WORKDIR}" ]] || rm -rf "${BACKUP_WORKDIR}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( ROLLBACK )); then
  record="${HISTORY_FILE}"
  [[ ! -f "${PENDING_FILE}" ]] || record="${PENDING_FILE}"
  [[ -f "${record}" ]] || die "No deployment snapshot to roll back to."
  SNAPSHOT="$(jq -er '.snapshot' "${record}")"
  [[ "${SNAPSHOT}" == "${DEPLOYMENTS_DIR}/"* && -f "${SNAPSHOT}/rollback.json" ]] \
    || die "Invalid deployment snapshot."
  MAINTENANCE_HELPER="${SNAPSHOT}/recovery.py"
  set -a
  source "${SNAPSHOT}/site.env"
  set +a
  # If quota-guard is still running it must report idle. A stopped/broken
  # stack can be recovered using its persisted attribution and task records.
  if [[ "$(docker inspect -f '{{.State.Status}}' clawshell-quota-guard 2>/dev/null || true)" == running ]]; then
    maintenance_idle
  else
    maintenance_persisted_idle
  fi
  if [[ -f "${SNAPSHOT}/backup" ]]; then
    confirm "Rollback restores the pre-update state/workspaces, replacing subsequent changes. Continue?" || exit 0
    # Preserve current data too, including when recovering a stopped stack.
    # This remains separate from the original pre-update recovery point.
    mapfile -t STOPPED_CONTAINERS < <(maintenance_running)
    if [[ -n "${STOPPED_CONTAINERS[0]:-}" ]]; then
      QUIESCED=1
      maintenance_stop
    else
      STOPPED_CONTAINERS=()
    fi
    maintenance_backup
    info "Pre-rollback safety backup: ${BACKUP_ARCHIVE}"
  fi
  journal recovering
  # A failed recovery must leave services stopped, not restart stale containers.
  QUIESCED=0
  recover || die "Rollback failed; snapshot retained at ${SNAPSHOT}."
  exit 0
fi
[[ ! -f "${PENDING_FILE}" ]] || die "An interrupted update needs recovery. Run $0 --rollback first."
[[ ! -e /opt/clawshell/maintenance-required ]] || die "An unresolved maintenance marker needs investigation before updating."
load_env
maintenance_idle
git fetch --tags --quiet
if [[ -z "${TARGET}" ]]; then
  TARGET="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" \
    || die "No upstream branch. Specify --to=<tag-or-commit>."
fi
TARGET="$(git rev-parse --verify --end-of-options "${TARGET}^{commit}")"
CURRENT_COMMIT="$(git rev-parse HEAD)"
git merge-base --is-ancestor "${CURRENT_COMMIT}" "${TARGET}" \
  || die "Target is not a fast-forward; use --rollback for recovery."
info "Update ${CURRENT_COMMIT} -> ${TARGET}"
# Check candidate settings without modifying the deployed tree.
missing="$(comm -23 \
  <(git show "${TARGET}:.env.example" | sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' | sort -u) \
  <(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' "${ENV_FILE}" | sort -u))"
[[ -z "${missing}" ]] || die "Missing .env settings: ${missing}. Add/review them before updating."
if (( CHECK )); then
  info "Fast-forward and settings checks passed. No deployment changes made."
  info "Builds, image availability and runtime readiness are checked during the update."
  exit 0
fi

SNAPSHOT="$(mktemp -d "${DEPLOYMENTS_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
cp "${MAINTENANCE_HELPER}" "${SNAPSHOT}/recovery.py"
MAINTENANCE_HELPER="${SNAPSHOT}/recovery.py"
printf '%s\n' "${CURRENT_COMMIT}" > "${SNAPSHOT}/commit"
cp -a "${ENV_FILE}" "${SNAPSHOT}/site.env"
maintenance_profiles
compose --profile '*' config --format json > "${SNAPSHOT}/before.json"
python3 "${MAINTENANCE_HELPER}" snapshot "${SNAPSHOT}/before.json" "${SNAPSHOT}/rollback.json"
journal prepared
# Mark mutation first so even interrupted Git operations enter recovery.
touch /opt/clawshell/maintenance-required
MUTATED=1
git merge --ff-only "${TARGET}"
compose "${PROFILES[@]}" config --format json > "${SNAPSHOT}/candidate.json"
# Local images are built rather than pulled from an unrelated registry.
compose "${PROFILES[@]}" --profile cli pull --ignore-buildable
compose "${PROFILES[@]}" build --pull
maintenance_idle
QUIESCED=1
maintenance_stop
journal stopped
maintenance_backup
printf '%s\n' "${BACKUP_ARCHIVE}" > "${SNAPSHOT}/backup"
journal activating
# New/changed files in existing workspaces are left to explicit operator review;
# do not run mutable upstream skill/plugin installers as part of this transaction.
compose "${PROFILES[@]}" up -d --pull never --no-build --force-recreate
STOPPED_CONTAINERS=()
# Compose retains profiles in rendered config; include selected profile services
# via its own service selection, excluding the on-demand CLI.
selected_services="$(compose "${PROFILES[@]}" config --services)"
mapfile -t SERVICES < <(grep -vx openclaw-cli <<<"${selected_services}")
maintenance_wait "${SNAPSHOT}/candidate.json" "${SERVICES[@]}"
journal healthy
cp "${PENDING_FILE}" "${HISTORY_FILE}.tmp"
mv "${HISTORY_FILE}.tmp" "${HISTORY_FILE}"
rm -f "${PENDING_FILE}" /opt/clawshell/maintenance-required
MUTATED=0
info "Update successful. Recovery snapshot: ${SNAPSHOT}"
