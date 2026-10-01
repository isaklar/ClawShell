#!/usr/bin/env bash
# Manual controls for the quota-guard circuit breaker + task attribution.
# See docs/quota-protection.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

CMD="${1:-status}"
shift || true

qg_exec() {
  docker exec clawshell-quota-guard python3 -c "$1"
}

case "${CMD}" in
  status)
    qg_exec "
import urllib.request, json
print(json.dumps(json.loads(urllib.request.urlopen('http://127.0.0.1:8088/status', timeout=3).read()), indent=2))
"
    ;;
  resume)
    HOST="${1:-}"
    PAYLOAD="{\"host\": \"${HOST}\"}"
    qg_exec "
import urllib.request
req = urllib.request.Request('http://127.0.0.1:8088/control/resume', data=b'${PAYLOAD}', method='POST', headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(req, timeout=3).read().decode())
"
    ;;
  reset-circuit)
    HOST="${1:?Usage: $0 reset-circuit <host>}"
    PAYLOAD="{\"host\": \"${HOST}\"}"
    qg_exec "
import urllib.request
req = urllib.request.Request('http://127.0.0.1:8088/control/reset-circuit', data=b'${PAYLOAD}', method='POST', headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(req, timeout=3).read().decode())
"
    ;;
  *)
    die "Usage: $0 {status|resume [host]|reset-circuit <host>}"
    ;;
esac
