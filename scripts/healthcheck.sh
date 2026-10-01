#!/usr/bin/env bash
# Prints a single, human-readable status summary. Used interactively and by
# the systemd timer (logs its output) and by install.sh/update.sh (--exit-code).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source scripts/lib/common.sh

EXIT_CODE=0
EXIT_ON_FAIL=0
[[ "${1:-}" == "--exit-code" ]] && EXIT_ON_FAIL=1

load_env 2>/dev/null || true

section() { printf '\n== %s ==\n' "$1"; }

container_status() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "not_found"
}

section "Containers"
for c in clawshell-openclaw-gateway clawshell-quota-guard clawshell-sandbox-dind; do
  status="$(container_status "${c}")"
  printf '%-32s %s\n' "${c}" "${status}"
  if [[ "${status}" != "running" ]]; then
    EXIT_CODE=1
  fi
done

section "Quota-guard"
QG_STATUS_JSON="$(docker exec clawshell-quota-guard python3 -c "
import urllib.request, json
print(urllib.request.urlopen('http://127.0.0.1:8088/status', timeout=3).read().decode())
" 2>/dev/null || echo '{}')"

if command -v jq >/dev/null 2>&1 && [[ -n "${QG_STATUS_JSON}" ]]; then
  ACTIVE_TASK="$(echo "${QG_STATUS_JSON}" | jq -r '.active_task // empty')"
  if [[ -n "${ACTIVE_TASK}" ]]; then
    TASK_ID="$(echo "${QG_STATUS_JSON}" | jq -r '.active_task.task_id')"
    USED="$(echo "${QG_STATUS_JSON}" | jq -r '.active_task.ai_requests_used')"
    MAX="$(echo "${QG_STATUS_JSON}" | jq -r '.active_task.max_ai_requests')"
    printf 'Current task:        %s\n' "${TASK_ID}"
    printf 'AI requests used:    %s / %s\n' "${USED}" "${MAX}"
  else
    printf 'Current task:        (none running)\n'
  fi

  OPEN_CIRCUITS="$(echo "${QG_STATUS_JSON}" | jq -r '.hosts | to_entries[] | select(.value.state != "CLOSED") | "\(.key): \(.value.state) (\(.value.reason))"')"
  if [[ -n "${OPEN_CIRCUITS}" ]]; then
    printf 'Quota state:          DEGRADED\n'
    echo "${OPEN_CIRCUITS}"
    EXIT_CODE=1
  else
    printf 'Quota state:          OK\n'
  fi
else
  printf 'Quota state:          UNKNOWN (quota-guard unreachable)\n'
  EXIT_CODE=1
fi

section "Network"
BLOCKED_LOG="/opt/clawshell/logs/quota-guard/blocked.log"
if [[ -f "${BLOCKED_LOG}" ]]; then
  ONE_HOUR_AGO_EPOCH=$(( $(date +%s) - 3600 ))
  BLOCKED_LAST_HOUR=$(awk -v cutoff="$(date -d "@${ONE_HOUR_AGO_EPOCH}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -r "${ONE_HOUR_AGO_EPOCH}" '+%Y-%m-%dT%H:%M:%S')" '$1 >= cutoff' "${BLOCKED_LOG}" 2>/dev/null | wc -l | tr -d ' ')
else
  BLOCKED_LAST_HOUR=0
fi
printf 'Network:              HEALTHY (%s blocked connections in last hour)\n' "${BLOCKED_LAST_HOUR}"

section "GitHub"
if docker exec clawshell-openclaw-gateway sh -c 'test -s /run/secrets/github_agent_token' 2>/dev/null; then
  printf 'GitHub:                HEALTHY (token present)\n'
else
  printf 'GitHub:                DEGRADED (token missing)\n'
  EXIT_CODE=1
fi

section "Disk usage"
DISK_PCT=$(df -P /opt/clawshell 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
WARN_PCT="${DISK_USAGE_WARN_PERCENT:-80}"
if [[ -n "${DISK_PCT:-}" ]]; then
  printf '/opt/clawshell:     %s%% used (warn threshold %s%%)\n' "${DISK_PCT}" "${WARN_PCT}"
  if [[ "${DISK_PCT}" -ge "${WARN_PCT}" ]]; then
    EXIT_CODE=1
  fi
fi

if [[ "${EXIT_ON_FAIL}" -eq 1 ]]; then
  exit "${EXIT_CODE}"
fi
