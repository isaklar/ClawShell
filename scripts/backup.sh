#!/usr/bin/env bash
# Consistent, verified state/config backup. See docs/operations.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
source scripts/lib/maintenance.sh
require_root
load_env
umask 077
MAINTENANCE_HELPER="${REPO_ROOT}/scripts/lib/recovery.py"
METADATA=
INCLUDE_SECRETS=0
for arg in "$@"; do
  case "${arg}" in
    --include-secrets) INCLUDE_SECRETS=1 ;;
    --metadata-only) METADATA=--metadata-only ;;
    --full-workspaces) : ;;
    *) die "Unknown argument: ${arg}" ;;
  esac
done
maintenance_require
maintenance_lock
[[ ! -e /opt/clawshell/maintenance-required ]] || die "Interrupted maintenance needs recovery before backup."
maintenance_idle
STOPPED_CONTAINERS=()
BACKUP_WORKDIR=
cleanup() {
  local rc=$?
  trap - EXIT
  maintenance_resume || { err "Failed to restart services after backup."; rc=1; }
  [[ -z "${BACKUP_WORKDIR}" ]] || rm -rf "${BACKUP_WORKDIR}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
maintenance_stop
maintenance_backup "${METADATA}"
maintenance_resume
if (( INCLUDE_SECRETS )); then
  # .env contains credentials too, so it belongs in the encrypted export.
  secret_tmp="${BACKUP_WORKDIR}/secrets.tar.age"
  tar -C /opt/clawshell -cf - secrets -C "${REPO_ROOT}" .env | age -p -o "${secret_tmp}"
  mv "${secret_tmp}" "${BACKUP_ARCHIVE%.tar.zst}-secrets.tar.age"
  info "Encrypted secrets/.env export written alongside backup. Store its passphrase separately."
fi
info "Automatic pruning is disabled (BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}); preserve deployment recovery points."
# No automatic deletion: deployment recovery points may reference old archives.
info "Backup complete. Model caches, .env and secrets are excluded from the plaintext archive."
