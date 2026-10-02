#!/usr/bin/env bash
# Verifies the black-box LIVE-testing kill switch is enforced in DEPTH, not only
# in the launcher: the target-gateway entrypoint itself refuses to start unless
# BLACKBOX_LIVE_TESTING=true, so a direct `docker compose --profile blackbox-live
# up` cannot arm the live boundary. Also sanity-checks the launcher gate and the
# EXIT/INT/TERM disarm trap are present. Pure static/behavioral checks — no
# Docker, no containers, safe on any machine.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0
ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }

ENTRY="target-gateway/entrypoint.sh"

echo "== target-gateway entrypoint kill switch =="

# The guard must come BEFORE anything is executed (python3 / mitmdump). We run
# the entrypoint with the flag unset/false; it must exit non-zero immediately.
# This is safe: the guard returns before control_api.py or mitmdump are spawned.
out="$(env -u BLACKBOX_LIVE_TESTING sh "${ENTRY}" 2>&1)"; rc=$?
if [[ "${rc}" -ne 0 ]]; then
  ok "refuses to start when BLACKBOX_LIVE_TESTING is unset (exit ${rc})"
else
  bad "started with BLACKBOX_LIVE_TESTING unset (should have refused)"
fi
if printf '%s' "${out}" | grep -qi "refusing to start"; then
  ok "prints a clear refusal message"
else
  bad "no refusal message printed (got: ${out})"
fi

out="$(BLACKBOX_LIVE_TESTING=false sh "${ENTRY}" 2>&1)"; rc=$?
if [[ "${rc}" -ne 0 ]]; then
  ok "refuses to start when BLACKBOX_LIVE_TESTING=false (exit ${rc})"
else
  bad "started with BLACKBOX_LIVE_TESTING=false (should have refused)"
fi

# The guard must precede `exec mitmdump` in source order.
guard_line="$(grep -n 'BLACKBOX_LIVE_TESTING' "${ENTRY}" | head -1 | cut -d: -f1)"
exec_line="$(grep -n 'exec mitmdump' "${ENTRY}" | head -1 | cut -d: -f1)"
if [[ -n "${guard_line}" && -n "${exec_line}" && "${guard_line}" -lt "${exec_line}" ]]; then
  ok "kill-switch guard precedes 'exec mitmdump' (line ${guard_line} < ${exec_line})"
else
  bad "kill-switch guard does not precede 'exec mitmdump'"
fi

# Upstream TLS verification must be asserted on (Alert 7 fix).
if grep -q 'ssl_insecure=false' "${ENTRY}"; then
  ok "asserts upstream TLS verification (ssl_insecure=false)"
else
  bad "entrypoint does not set ssl_insecure=false"
fi

echo "== launcher (scripts/pentest-task.sh) gating + teardown =="
LAUNCHER="scripts/pentest-task.sh"

if grep -q 'BLACKBOX_LIVE_TESTING:-false.*== "true"' "${LAUNCHER}" \
   || grep -q 'Live testing is disabled' "${LAUNCHER}"; then
  ok "launcher refuses --live unless BLACKBOX_LIVE_TESTING=true"
else
  bad "launcher is missing the BLACKBOX_LIVE_TESTING gate"
fi

if grep -q 'trap disarm_live EXIT INT TERM' "${LAUNCHER}"; then
  ok "installs disarm_live trap on EXIT/INT/TERM"
else
  bad "no disarm_live EXIT/INT/TERM trap (a crash could leak the live lane)"
fi

if grep -q 'disarm_live()' "${LAUNCHER}"; then
  ok "defines an idempotent disarm_live() teardown"
else
  bad "disarm_live() not defined"
fi

echo "== compose kill-switch wiring =="
COMPOSE="compose/compose.yml"
count="$(grep -c 'BLACKBOX_LIVE_TESTING' "${COMPOSE}")"
if [[ "${count}" -ge 2 ]]; then
  ok "BLACKBOX_LIVE_TESTING passed into the blackbox-live services (${count} refs)"
else
  bad "BLACKBOX_LIVE_TESTING not wired into both blackbox-live services (found ${count})"
fi

if [[ "${FAIL}" -eq 0 ]]; then
  echo "Black-box kill-switch checks PASSED."
else
  echo "Black-box kill-switch checks FAILED."
fi
exit "${FAIL}"
