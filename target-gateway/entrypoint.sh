#!/usr/bin/env sh
set -eu

# Run the control API in the background, mitmdump (the scoped target-traffic
# proxy with our addon) in the foreground. Same proven two-process pattern as
# quota-guard, but a separate component with a separate purpose (black-box
# live-testing boundary, not SaaS-cost control).
python3 /app/control_api.py &
CONTROL_PID=$!

trap 'kill "$CONTROL_PID" 2>/dev/null || true' TERM INT

exec mitmdump \
  --mode regular \
  --listen-port 8080 \
  --set confdir=/state/mitmproxy \
  --scripts /app/addons/target_gateway_addon.py \
  --set termlog_verbosity=info
