#!/usr/bin/env bash
# Adds/removes host-specific egress allowlist entries (e.g. an internal service
# on your LAN), hot-reloaded by quota-guard on the next request (it reads
# allowlist.d/ on every check, no restart needed). See docs/networking.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/common.sh

CMD="${1:-list}"
ENTRY="${2:-}"
DIR="config/allowlist.d"
mkdir -p "${DIR}"

case "${CMD}" in
  add)
    [[ -n "${ENTRY}" ]] || die "Usage: $0 add <host:port>"
    SAFE_NAME="$(echo "${ENTRY}" | tr -c 'a-zA-Z0-9' '-')"
    echo "${ENTRY}" >> "${DIR}/${SAFE_NAME}.conf"
    info "Added ${ENTRY} to the egress allowlist (${DIR}/${SAFE_NAME}.conf)."
    ;;
  remove)
    [[ -n "${ENTRY}" ]] || die "Usage: $0 remove <host:port>"
    SAFE_NAME="$(echo "${ENTRY}" | tr -c 'a-zA-Z0-9' '-')"
    rm -f "${DIR}/${SAFE_NAME}.conf"
    info "Removed ${ENTRY} from the egress allowlist."
    ;;
  list)
    cat "${DIR}"/*.conf 2>/dev/null || echo "(no host-specific entries)"
    ;;
  *)
    die "Usage: $0 {add|remove|list} [host:port]"
    ;;
esac
