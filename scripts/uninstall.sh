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
systemctl disable --now clawshell-firewall.service 2>/dev/null || true
rm -f /etc/systemd/system/clawshell-firewall.service
systemctl daemon-reload
nft delete table inet clawshell 2>/dev/null || true
rm -f /etc/clawshell/nftables.conf
rmdir /etc/clawshell 2>/dev/null || true
info "Removed nftables table inet clawshell."
# Older releases overwrote /etc/nftables.conf instead of using their own table.
LATEST_BACKUP="$(ls -t /opt/clawshell/backups/nftables.conf.pre-install.* 2>/dev/null | head -1 || true)"
if [[ -n "${LATEST_BACKUP}" ]] && grep -q 'clawshell nftables ruleset template' /etc/nftables.conf 2>/dev/null; then
  cp "${LATEST_BACKUP}" /etc/nftables.conf
  nft -f /etc/nftables.conf || warn "Failed to restore pre-install nftables ruleset; check manually."
  info "Restored legacy pre-install /etc/nftables.conf from ${LATEST_BACKUP}."
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
