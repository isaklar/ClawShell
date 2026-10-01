#!/usr/bin/env bash
# Verifies the Gateway container cannot read host paths it shouldn't, and has
# no docker.sock mounted.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

FAIL=0

for path in /etc/shadow /root/.ssh /var/lib/docker /var/run/docker.sock; do
  if docker exec clawshell-openclaw-gateway sh -c "test -e '${path}'" 2>/dev/null; then
    err "FAIL: ${path} is visible inside the Gateway container (should not exist there)"
    FAIL=1
  else
    info "OK: ${path} not present in Gateway container"
  fi
done

# Docker socket must not be mounted anywhere.
if docker inspect clawshell-openclaw-gateway --format '{{json .Mounts}}' | grep -q 'docker.sock'; then
  err "FAIL: docker.sock is mounted into the Gateway container"
  FAIL=1
else
  info "OK: no docker.sock mount on the Gateway container"
fi

# Root filesystem should be read-only.
RO="$(docker inspect clawshell-openclaw-gateway --format '{{.HostConfig.ReadonlyRootfs}}')"
if [[ "${RO}" != "true" ]]; then
  err "FAIL: Gateway container root filesystem is not read-only"
  FAIL=1
else
  info "OK: Gateway root filesystem is read-only"
fi

if [[ "${FAIL}" -eq 1 ]]; then
  err "Filesystem isolation test FAILED."
  exit 1
fi
info "Filesystem isolation test PASSED."
