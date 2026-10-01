#!/usr/bin/env bash
# Restores a backup produced by backup.sh. Verifies checksum, shows a diff
# preview, asks for confirmation, then swaps state/config in and restarts.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
require_root

ARCHIVE="${1:-}"
[[ -n "${ARCHIVE}" && -f "${ARCHIVE}" ]] || die "Usage: $0 <path-to-backup.tar.zst>"

[[ -f "${ARCHIVE}.sha256" ]] && (cd "$(dirname "${ARCHIVE}")" && sha256sum -c "$(basename "${ARCHIVE}").sha256") \
  || warn "No checksum file found next to ${ARCHIVE}; proceeding without verification."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
zstd -dq -c "${ARCHIVE}" | tar -C "${WORKDIR}" -xf -

echo "----- Restore preview -----"
diff -rq /opt/clawshell/state "${WORKDIR}/state" || true
diff -rq config "${WORKDIR}/config" || true
echo "----------------------------"

confirm "Apply this restore? Current state/config will be overwritten." || { info "Cancelled."; exit 0; }

info "Stopping services..."
compose down

rsync -a --delete "${WORKDIR}/state/" /opt/clawshell/state/
rsync -a --delete "${WORKDIR}/config/" config/

if [[ -d "${WORKDIR}/workspaces" ]]; then
  rsync -a "${WORKDIR}/workspaces/" /opt/clawshell/workspaces/
fi

chown -R clawshell:clawshell /opt/clawshell/state

info "Starting services..."
compose up -d
sleep 5
scripts/healthcheck.sh
