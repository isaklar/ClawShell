#!/usr/bin/env bash
# Runs every test in tests/. Static/unit tests (no deployed host required)
# always run. Live-host tests (need a running clawshell deployment) run
# only if the Gateway container is detected, otherwise they're reported as
# SKIPPED — this lets you run the full regression suite from a dev laptop
# and get real signal, without requiring the actual deployment host.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

STATIC_TESTS=(
  tests/test-static-validation.sh
  tests/test-credential-provider-logic.sh
  tests/test-github-repo-scope-logic.sh
  tests/test-blackbox-killswitch.sh
  tests/test-python-unit.sh
)
LIVE_TESTS=(
  tests/test-filesystem-isolation.sh
  tests/test-network-isolation.sh
  tests/test-quota-guard-circuit-breaker.sh
)
MANUAL_TESTS=(
  tests/test-task-runtime-limit.sh
)

PASS=0
FAIL=0
SKIP=0

run_one() {
  local script="$1"
  echo
  echo "=============================================================="
  echo "RUNNING: ${script}"
  echo "=============================================================="
  if bash "${script}"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("${script}")
  fi
}

FAILED_TESTS=()

for t in "${STATIC_TESTS[@]}"; do
  run_one "${t}"
done

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'clawshell-openclaw-gateway'; then
  echo
  echo "Detected a running clawshell-openclaw-gateway container — running live-host tests too."
  for t in "${LIVE_TESTS[@]}"; do
    run_one "${t}"
  done
else
  echo
  echo "No running clawshell-openclaw-gateway container detected — skipping live-host tests:"
  for t in "${LIVE_TESTS[@]}"; do
    echo "  SKIP ${t} (requires a deployed/running clawshell host)"
    SKIP=$((SKIP + 1))
  done
fi

echo
echo "Manual/outline tests (not auto-run, documented steps only):"
for t in "${MANUAL_TESTS[@]}"; do
  echo "  MANUAL ${t} — run by hand per its own instructions"
done

echo
echo "=============================================================="
echo "SUMMARY: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "=============================================================="
if [[ "${FAIL}" -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
