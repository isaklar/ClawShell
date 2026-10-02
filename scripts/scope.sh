#!/usr/bin/env bash
# Operator controls for black-box LIVE testing (the target-gateway scope +
# approval boundary). See docs/blackbox-live-testing.md.
#
# Live testing is deny-by-default and gated two ways:
#   1. SCOPE   - which targets exist at all. Edit config/engagement-scope.conf
#                (or whatever you pass to pentest-task.sh --scope-file) BEFORE
#                arming the engagement. The agents can never widen it.
#   2. APPROVAL- within scope, state-changing (non-idempotent) requests are held
#                until you approve the exact descriptor the gateway printed, of
#                the form "METHOD host:port/firstpathsegment".
#
# This talks to target-gateway's loopback control API via `docker exec`; it is
# never published to the host (see compose/compose.yml).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

CONTAINER="clawshell-target-gateway"
BASE="http://127.0.0.1:8089"

reachable_or_die() {
  docker exec "${CONTAINER}" python3 -c "
import urllib.request;urllib.request.urlopen('${BASE}/status', timeout=3)" >/dev/null 2>&1 || die \
    "Cannot reach target-gateway (${CONTAINER}). Is a black-box LIVE engagement armed? Start one with: ./scripts/pentest-task.sh --mode black-box --live --scope-file <scope.conf> --spec <spec>"
}

# POST {"descriptor": "<value>"} to <path>, passing the descriptor as a
# container env var so no untrusted text is interpolated into the python source.
post_descriptor() {
  local path="$1" descriptor="$2"
  docker exec -e DESC="${descriptor}" "${CONTAINER}" python3 -c "
import os, json, urllib.request
body = json.dumps({'descriptor': os.environ['DESC']}).encode()
req = urllib.request.Request('${BASE}${path}', data=body, method='POST', headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(req, timeout=3).read().decode())
"
}

CMD="${1:-status}"
shift || true

case "${CMD}" in
  status)
    reachable_or_die
    docker exec "${CONTAINER}" python3 -c "
import urllib.request, json
print(json.dumps(json.loads(urllib.request.urlopen('${BASE}/status', timeout=3).read()), indent=2))
"
    ;;
  approve)
    DESCRIPTOR="${1:?Usage: $0 approve '<METHOD host:port/segment>' (copy the descriptor from the agent/gateway approval_required message)}"
    reachable_or_die
    info "Approving: ${DESCRIPTOR}"
    post_descriptor "/control/approve" "${DESCRIPTOR}"
    ;;
  revoke)
    DESCRIPTOR="${1:?Usage: $0 revoke '<METHOD host:port/segment>'}"
    reachable_or_die
    info "Revoking: ${DESCRIPTOR}"
    post_descriptor "/control/revoke" "${DESCRIPTOR}"
    ;;
  *)
    die "Usage: $0 {status | approve '<descriptor>' | revoke '<descriptor>'}
  status                 show active engagement, in-scope hosts, granted approvals
  approve '<descriptor>' grant one Tier 1 (state-changing) action, e.g. 'POST api.example.com:443/login'
  revoke  '<descriptor>' withdraw a previously granted approval"
    ;;
esac
