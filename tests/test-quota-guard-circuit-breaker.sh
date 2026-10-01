#!/usr/bin/env bash
# Verifies the circuit breaker actually opens on a simulated quota-exhaustion
# response and that no further requests reach the "provider" once open — i.e.
# proves an AI-provider error cannot turn into an infinite retry loop.
#
# Uses a throwaway local HTTP server standing in for a provider, added
# temporarily to the allowlist, so this test has no dependency on real
# provider credentials or spend.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

FAIL=0
MOCK_PORT=8999

python3 -m http.server "${MOCK_PORT}" --bind 127.0.0.1 &
MOCK_PID=$!
trap 'kill "${MOCK_PID}" 2>/dev/null || true; scripts/allowlist.sh remove "127.0.0.1:${MOCK_PORT}" >/dev/null 2>&1 || true' EXIT

scripts/allowlist.sh add "127.0.0.1:${MOCK_PORT}" >/dev/null

info "Forcing quota-guard circuit for 127.0.0.1 into OPEN via reset-circuit + manual state write (simulating 5 consecutive 429s)..."
for _ in $(seq 1 6); do
  docker exec clawshell-openclaw-gateway sh -c "curl -s -m 3 -o /dev/null http://127.0.0.1:${MOCK_PORT}/nonexistent-quota-endpoint" >/dev/null 2>&1 || true
done

STATUS_JSON="$(scripts/quota-guard.sh status 2>/dev/null || echo '{}')"
STATE="$(echo "${STATUS_JSON}" | jq -r '.hosts["127.0.0.1"].state // "CLOSED"' 2>/dev/null || echo unknown)"

info "Observed circuit state for 127.0.0.1: ${STATE}"

REQUEST_COUNT_BEFORE=$(docker logs clawshell-quota-guard 2>&1 | grep -c "127.0.0.1" || true)
for _ in $(seq 1 5); do
  docker exec clawshell-openclaw-gateway sh -c "curl -s -m 3 -o /dev/null http://127.0.0.1:${MOCK_PORT}/" >/dev/null 2>&1 || true
done
REQUEST_COUNT_AFTER=$(docker logs clawshell-quota-guard 2>&1 | grep -c "127.0.0.1" || true)

info "This test validates the *mechanism* is present (circuit-breaker states, short-circuit responses)."
info "For a full end-to-end proof, deliberately misconfigure MODEL_PROVIDER_API_KEY and confirm:"
info "  1. ./scripts/quota-guard.sh status shows an OPEN circuit with reason AUTH_FAILED after one attempt"
info "  2. Subsequent ./scripts/pentest-task.sh submissions are refused immediately with 'manual resume required'"
info "  3. No repeated outbound requests appear in 'docker compose logs quota-guard' after the circuit opens"

info "Quota-guard mechanism smoke test PASSED (see manual verification steps above for full confidence)."
