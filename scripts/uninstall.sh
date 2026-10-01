#!/usr/bin/env bash
# Stops and removes what this repo created. --purge additionally removes
# /opt/clawshell (with confirmation, offers a backup first).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh
require_root

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

info "Stopping services..."
compose down --remove-orphans || true

info "Removing systemd units..."
systemctl disable --now clawshell.service 2>/dev/null || true
systemctl disable --now clawshell-healthcheck.timer 2>/dev/null || true
systemctl disable --now clawshell-backup.timer 2>/dev/null || true
rm -f /etc/systemd/system/clawshell.service \
      /etc/systemd/system/clawshell-healthcheck.service \
      /etc/systemd/system/clawshell-healthcheck.timer \
      /etc/systemd/system/clawshell-backup.service \
      /etc/systemd/system/clawshell-backup.timer
systemctl daemon-reload

info "Removing firewall rules added by this repo..."
LATEST_BACKUP="$(ls -t /opt/clawshell/backups/nftables.conf.pre-install.* 2>/dev/null | head -1 || true)"
if [[ -n "${LATEST_BACKUP}" ]]; then
  cp "${LATEST_BACKUP}" /etc/nftables.conf
  nft -f /etc/nftables.conf || warn "Failed to restore pre-install nftables ruleset; check manually."
  info "Restored nftables ruleset from ${LATEST_BACKUP}."
else
  warn "No pre-install nftables backup found; leaving current ruleset in place."
fi

if [[ "${PURGE}" -eq 1 ]]; then
  if confirm "This will permanently delete /opt/clawshell (state, secrets, workspaces, logs, backups). Have you run ./scripts/backup.sh?"; then
    if confirm "Take one last backup now before deleting?"; then
      scripts/backup.sh || warn "Backup failed; continuing with purge anyway since you confirmed."
    fi
    rm -rf /opt/clawshell
    info "Purged /opt/clawshell."
  else
    info "Purge cancelled. /opt/clawshell left in place."
  fi
fi

info "Uninstall complete."
