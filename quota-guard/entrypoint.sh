#!/usr/bin/env sh
set -eu

# Run the control API in the background, mitmdump (transparent HTTPS proxy
# with our addon) in the foreground. Both are stdlib/mitmproxy only — no
# supervisor daemon needed for two processes in one purpose-built container.
python3 /app/control_api.py &
CONTROL_PID=$!

trap 'kill "$CONTROL_PID" 2>/dev/null || true' TERM INT

exec mitmdump \
  --mode regular \
  --listen-port 8080 \
  --set confdir=/state/mitmproxy \
  --scripts /app/addons/quota_guard_addon.py \
  --set termlog_verbosity=info
