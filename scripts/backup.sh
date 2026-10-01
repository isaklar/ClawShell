#!/usr/bin/env bash
# Backs up persistent state/config (never secrets, unless --include-secrets is
# explicitly passed) to /opt/clawshell/backups/clawshell-<ts>.tar.zst.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

INCLUDE_SECRETS=0
METADATA_ONLY_WORKSPACES=0
for arg in "$@"; do
  case "${arg}" in
    --include-secrets) INCLUDE_SECRETS=1 ;;
    --metadata-only) METADATA_ONLY_WORKSPACES=1 ;;
    --full-workspaces) : ;; # full workspace backup is now the default; flag kept as a no-op for backward compatibility
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/state" "${WORKDIR}/config"
cp -a /opt/clawshell/state/openclaw "${WORKDIR}/state/" 2>/dev/null || true
cp -a /opt/clawshell/state/quota-guard "${WORKDIR}/state/" 2>/dev/null || true
cp -a config/allowlist.conf config/openclaw.json5 "${WORKDIR}/config/" 2>/dev/null || true
cp -a config/allowlist.d "${WORKDIR}/config/" 2>/dev/null || true

if [[ "${METADATA_ONLY_WORKSPACES}" -eq 1 ]]; then
  mkdir -p "${WORKDIR}/workspaces-metadata"
  for repo in /opt/clawshell/workspaces/*/; do
    [[ -d "${repo}/.git" ]] || continue
    name="$(basename "${repo}")"
    {
      echo "remote: $(git -C "${repo}" remote get-url origin 2>/dev/null || echo unknown)"
      echo "branch: $(git -C "${repo}" branch --show-current 2>/dev/null || echo unknown)"
    } > "${WORKDIR}/workspaces-metadata/${name}.txt"
  done
else
  cp -a /opt/clawshell/workspaces "${WORKDIR}/workspaces"
fi

ARCHIVE="/opt/clawshell/backups/clawshell-${TS}.tar.zst"
tar -C "${WORKDIR}" -cf - . | zstd -q -o "${ARCHIVE}"
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"
info "Backup written to ${ARCHIVE}"

if [[ "${INCLUDE_SECRETS}" -eq 1 ]]; then
  SECRETS_ARCHIVE="/opt/clawshell/backups/clawshell-secrets-${TS}.tar.age"
  tar -C /opt/clawshell -cf - secrets | age -p -o "${SECRETS_ARCHIVE}"
  warn "Secrets backup written to ${SECRETS_ARCHIVE} (age-encrypted, passphrase-protected). Store it somewhere separate from this box."
fi

# Retention
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
find /opt/clawshell/backups -name 'clawshell-*.tar.zst*' -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true

info "Done."
