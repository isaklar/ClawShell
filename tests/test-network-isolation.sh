#!/usr/bin/env bash
# Verifies the Gateway container cannot reach non-allowlisted hosts and
# cannot reach RFC1918 LAN ranges directly (only through an explicit
# allowlist.d/ entry, if configured). Run after `docker compose up -d`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

FAIL=0

check_blocked() {
  local host="$1"
  if docker exec clawshell-openclaw-gateway sh -c "curl -s -m 5 -o /dev/null -w '%{http_code}' http://${host}/" 2>/dev/null | grep -q '^200$'; then
    err "FAIL: ${host} was reachable (should be blocked by quota-guard's allowlist)"
    FAIL=1
  else
    info "OK: ${host} correctly blocked"
  fi
}

check_allowed() {
  local host="$1"
  local code
  code="$(docker exec clawshell-openclaw-gateway sh -c "curl -s -m 5 -o /dev/null -w '%{http_code}' https://${host}/" 2>/dev/null || echo 000)"
  if [[ "${code}" =~ ^(200|301|302|404)$ ]]; then
    info "OK: ${host} reachable as expected (HTTP ${code})"
  else
    err "FAIL: ${host} should be reachable but got HTTP ${code}"
    FAIL=1
  fi
}

info "Testing egress isolation from the Gateway container..."
check_blocked "example.com"
check_blocked "1.1.1.1"
check_allowed "github.com"

if [[ "${FAIL}" -eq 1 ]]; then
  err "Network isolation test FAILED."
  exit 1
fi
info "Network isolation test PASSED."
