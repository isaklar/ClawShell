#!/usr/bin/env sh
set -eu

# Kill switch enforced at the service itself, not only in the launcher: a direct
# `docker compose --profile blackbox-live up` must not start the live boundary
# unless black-box live testing is explicitly enabled.
if [ "$(printf '%s' "${BLACKBOX_LIVE_TESTING:-}" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
  echo "target-gateway: refusing to start; BLACKBOX_LIVE_TESTING is not 'true'." >&2
  exit 1
fi

# Run the control API in the background, mitmdump (the scoped target-traffic
# proxy with our addon) in the foreground. Same proven two-process pattern as
# quota-guard, but a separate component with a separate purpose (black-box
# live-testing boundary, not SaaS-cost control).
python3 /app/control_api.py &
CONTROL_PID=$!

trap 'kill "$CONTROL_PID" 2>/dev/null || true' TERM INT

# ssl_insecure=false asserts that the gateway performs real upstream TLS
# verification to the target (the MCP client trusts the gateway for this).
exec mitmdump \
  --mode regular \
  --listen-port 8080 \
  --set confdir=/state/mitmproxy \
  --set ssl_insecure=false \
  --scripts /app/addons/target_gateway_addon.py \
  --set termlog_verbosity=info
