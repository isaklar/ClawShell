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

# Per-subdir so state the backup doesn't contain (model caches, sandbox-dind)
# is left alone instead of being --delete'd.
for src in "${WORKDIR}"/state/*/; do
  [[ -d "${src}" ]] || continue
  rsync -a --delete "${src}" "/opt/clawshell/state/$(basename "${src}")/"
done
# Older backups carry the live OpenClaw config as config/openclaw.json5; it now
# lives in state/openclaw-config (config/openclaw.json5 is a symlink to it).
if [[ -f "${WORKDIR}/config/openclaw.json5" ]]; then
  install -d -m 0755 /opt/clawshell/state/openclaw-config
  install -m 0644 "${WORKDIR}/config/openclaw.json5" /opt/clawshell/state/openclaw-config/openclaw.json5
fi
# Only restore what backup.sh saves; never --delete the repo's tracked files.
[[ -f "${WORKDIR}/config/allowlist.conf" ]] && cp -a "${WORKDIR}/config/allowlist.conf" config/allowlist.conf
[[ -d "${WORKDIR}/config/allowlist.d" ]] && rsync -a --delete "${WORKDIR}/config/allowlist.d/" config/allowlist.d/
ln -sfn /opt/clawshell/state/openclaw-config/openclaw.json5 config/openclaw.json5

if [[ -d "${WORKDIR}/workspaces" ]]; then
  rsync -a "${WORKDIR}/workspaces/" /opt/clawshell/workspaces/
fi

for d in openclaw openclaw-config caveman; do
  [[ -d "/opt/clawshell/state/${d}" ]] && chown -R clawshell:clawshell "/opt/clawshell/state/${d}"
done
# Fixed in-image UIDs, see install.sh Phase 3.
chown -R 10001:10001 /opt/clawshell/state/quota-guard 2>/dev/null || true

info "Starting services..."
compose up -d
sleep 5
scripts/healthcheck.sh
