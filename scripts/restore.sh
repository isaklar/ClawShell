#!/usr/bin/env bash
# Strict component restore with a durable, offline recovery path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
source scripts/lib/maintenance.sh
require_root
umask 077
MAINTENANCE_HELPER="${REPO_ROOT}/scripts/lib/recovery.py"
RECOVER=0
ARCHIVE=
if [[ $# == 1 && "$1" == --recover ]]; then
  RECOVER=1
elif [[ $# == 1 && -f "$1" ]]; then
  ARCHIVE="$(realpath "$1")"
else
  die "Usage: $0 <backup.tar.zst> | --recover"
fi
maintenance_require
maintenance_lock
[[ ! -f "${DEPLOYMENTS_DIR}/pending.json" ]] || die "An update needs recovery; run update.sh --rollback first."
RESTORE_ROOT=/opt/clawshell/restores
RESTORE_PENDING="${RESTORE_ROOT}/pending.json"
mkdir -p "${RESTORE_ROOT}"
chmod 700 "${RESTORE_ROOT}"
STOPPED_CONTAINERS=()
BACKUP_WORKDIR=
WORKDIR=
WRITING=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( rc != 0 && WRITING )); then
    err "Restore failed; recovery journal retained. Services may be stopped or unhealthy."
    err "Run sudo ./scripts/restore.sh --recover to restore the safety backup."
  else
    maintenance_resume || rc=1
  fi
  # Retain the before-config and helper if writing was attempted, even on failure.
  if (( ! WRITING )) && [[ -n "${WORKDIR}" && ! -f "${RESTORE_PENDING}" ]]; then
    rm -rf "${WORKDIR}"
  fi
  [[ -z "${BACKUP_WORKDIR}" ]] || rm -rf "${BACKUP_WORKDIR}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( RECOVER )); then
  [[ -f "${RESTORE_PENDING}" ]] || die "No interrupted restore to recover."
  WORKDIR="$(jq -er '.directory' "${RESTORE_PENDING}")"
  [[ "${WORKDIR}" == "${RESTORE_ROOT}/"* && -f "${WORKDIR}/rollback.json" ]] \
    || die "Invalid restore recovery directory."
  MAINTENANCE_HELPER="${WORKDIR}/recovery.py"
  ARCHIVE="$(cat "${WORKDIR}/safety-backup")"
  if [[ "$(docker inspect -f '{{.State.Status}}' clawshell-quota-guard 2>/dev/null || true)" == running ]]; then
    maintenance_idle
  else
    maintenance_persisted_idle
  fi
  confirm "Restore the pre-restore safety backup, replacing changes since that backup?" || exit 0
  # No new tasks are allowed while the durable maintenance marker exists.
  # Stop any writers without depending on potentially broken restored config.
  running="$(maintenance_running)"
  if [[ -n "${running}" ]]; then
    docker stop ${running//$'\n'/ } >/dev/null
  fi
  recovery_tmp="$(mktemp -d "${WORKDIR}/recover-XXXXXXXX")"
  WRITING=1
  maintenance_verify_archive "${ARCHIVE}" "${recovery_tmp}"
  python3 "${MAINTENANCE_HELPER}" restore "${recovery_tmp}/contents" "${REPO_ROOT}" /opt/clawshell
else
  [[ ! -f "${RESTORE_PENDING}" ]] || die "An interrupted restore needs --recover first."
  [[ ! -e /opt/clawshell/maintenance-required ]] || die "Interrupted maintenance needs recovery first."
  load_env
  WORKDIR="$(mktemp -d "${RESTORE_ROOT}/restore-XXXXXXXX")"
  cp "${MAINTENANCE_HELPER}" "${WORKDIR}/recovery.py"
  MAINTENANCE_HELPER="${WORKDIR}/recovery.py"
  maintenance_verify_archive "${ARCHIVE}" "${WORKDIR}"
  info "Restore manifest (only these paths are replaced):"
  cat "${WORKDIR}/contents/manifest.json"
  confirm "Restore these components? Current contents of these paths will be replaced." || exit 0
  maintenance_idle
  maintenance_profiles
  compose --profile '*' config --format json > "${WORKDIR}/compose.json"
  python3 "${MAINTENANCE_HELPER}" snapshot "${WORKDIR}/compose.json" "${WORKDIR}/rollback.json"
  maintenance_stop
  maintenance_backup
  printf '%s\n' "${BACKUP_ARCHIVE}" > "${WORKDIR}/safety-backup"
  # Save the timeout without relying on a future site's .env being valid.
  printf '%s\n' "${UPDATE_HEALTH_TIMEOUT:-600}" > "${WORKDIR}/health-timeout"
  jq -n --arg directory "${WORKDIR}" '{directory: $directory}' > "${RESTORE_PENDING}.tmp"
  mv "${RESTORE_PENDING}.tmp" "${RESTORE_PENDING}"
  touch /opt/clawshell/maintenance-required
  WRITING=1
  python3 "${MAINTENANCE_HELPER}" restore "${WORKDIR}/contents" "${REPO_ROOT}" /opt/clawshell
fi
# Recreate so replaced bind-mounted files/directories are picked up.
saved_services="$(jq -er '.[]' "${WORKDIR}/services.json")"
mapfile -t SERVICES <<<"${saved_services}"
docker compose --project-directory "${REPO_ROOT}/compose" -f "${WORKDIR}/rollback.json" \
  up -d --force-recreate --pull never --no-build "${SERVICES[@]}"
STOPPED_CONTAINERS=()
UPDATE_HEALTH_TIMEOUT="$(cat "${WORKDIR}/health-timeout")"
maintenance_wait "${WORKDIR}/rollback.json" "${SERVICES[@]}"
rm -f "${RESTORE_PENDING}" /opt/clawshell/maintenance-required
WRITING=0
info "Restore complete. Safety backup: $(cat "${WORKDIR}/safety-backup")"
