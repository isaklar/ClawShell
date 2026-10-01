#!/usr/bin/env bash
# Pulls new images/config and recreates services, with automatic rollback on
# a failed post-update healthcheck. See docs/operations.md for the full flow.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

FORCE=0
ROLLBACK=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --rollback) ROLLBACK=1 ;;
  esac
done

HISTORY_FILE="/opt/clawshell/state/update-history.json"

if [[ "${ROLLBACK}" -eq 1 ]]; then
  [[ -f "${HISTORY_FILE}" ]] || die "No update history found at ${HISTORY_FILE}; nothing to roll back to."
  PREV_COMMIT="$(jq -r '.previous_commit' "${HISTORY_FILE}")"
  info "Rolling back git tree to ${PREV_COMMIT}..."
  git checkout "${PREV_COMMIT}"
  compose up -d
  sync_caveman_proxy_state
  sync_local_llm_state
  scripts/healthcheck.sh --exit-code || warn "Healthcheck still failing after rollback; manual investigation needed."
  exit 0
fi

if [[ "${FORCE}" -eq 0 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    die "Working tree is dirty. Commit/stash changes or re-run with --force."
  fi
fi

CURRENT_COMMIT="$(git rev-parse HEAD)"
info "Current commit: ${CURRENT_COMMIT}"

git fetch --quiet
git pull --ff-only

info "Checking for new required .env keys..."
NEW_KEYS="$(comm -23 \
  <(grep -oE '^[A-Z_]+=' .env.example | sort -u) \
  <(grep -oE '^[A-Z_]+=' .env | sort -u) || true)"
if [[ -n "${NEW_KEYS}" ]]; then
  die "New required keys appeared in .env.example that are missing from .env: ${NEW_KEYS} — add them, then re-run update.sh."
fi

CURRENT_IMAGES="$(compose images -q | sort -u)"

compose pull
compose build quota-guard
scripts/setup-team.sh || warn "Agent team workspace seeding failed/skipped — non-fatal, continuing."
compose up -d
sync_caveman_proxy_state
sync_local_llm_state

scripts/install-caveman-skill.sh || warn "Caveman skill re-install failed/skipped — non-fatal, continuing."

sleep 5
if scripts/healthcheck.sh --exit-code; then
  jq -n --arg prev "${CURRENT_COMMIT}" --arg now "$(git rev-parse HEAD)" --arg ts "$(date -Is)" \
    '{previous_commit: $prev, updated_to: $now, updated_at: $ts}' > "${HISTORY_FILE}"
  info "Update successful."
else
  err "Post-update healthcheck failed. Rolling back automatically."
  git checkout "${CURRENT_COMMIT}"
  compose up -d
  sync_caveman_proxy_state
  sync_local_llm_state
  scripts/healthcheck.sh --exit-code || err "Still unhealthy after rollback — manual intervention required."
  exit 1
fi
