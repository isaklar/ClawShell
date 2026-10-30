#!/usr/bin/env bash
# Default: static/unit tests only. --integration additionally creates an
# isolated Docker stack; an existing production Gateway never triggers tests.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

STATIC_TESTS=(
  tests/test-static-validation.sh
  tests/test-install-packages.sh
  tests/test-credential-provider-logic.sh
  tests/test-github-repo-scope-logic.sh
  tests/test-blackbox-killswitch.sh
  tests/test-python-unit.sh
)
MANUAL_TESTS=(
  tests/test-task-runtime-limit.sh
)

INTEGRATION=0
case "${1:-}" in
  "") ;;
  --integration) INTEGRATION=1 ;;
  *) echo "Usage: $0 [--integration]" >&2; exit 2 ;;
esac

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

if [[ "${INTEGRATION}" -eq 1 ]]; then
  run_one tests/run-integration.sh
else
  echo
  echo "Isolated Docker integration suite not requested (run tests/run-integration.sh)."
  SKIP=$((SKIP + 1))
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
