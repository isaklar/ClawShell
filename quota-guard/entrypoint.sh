#!/usr/bin/env sh
set -eu

# Run the control API in the background, mitmdump (transparent HTTPS proxy
# with our addon) in the foreground. Both are stdlib/mitmproxy only — no
# supervisor daemon needed for two processes in one purpose-built container.
python3 /app/control_api.py &
CONTROL_PID=$!

# mitmproxy intercepts TLS, so clients must trust its CA. Publish ONLY the
# public cert (never mitmproxy-ca.pem, which contains the private key) to a
# separate dir that compose mounts read-only into the Node/Go clients.
mkdir -p /state/public-ca
(
  while :; do
    if [ -s /state/mitmproxy/mitmproxy-ca-cert.pem ]; then
      if ! cmp -s /state/mitmproxy/mitmproxy-ca-cert.pem /state/public-ca/clawshell-egress-ca.pem 2>/dev/null; then
        cp /state/mitmproxy/mitmproxy-ca-cert.pem /state/public-ca/.ca.tmp \
          && chmod 0644 /state/public-ca/.ca.tmp \
          && mv /state/public-ca/.ca.tmp /state/public-ca/clawshell-egress-ca.pem
      fi
    fi
    sleep 5
  done
) &
CA_PID=$!

trap 'kill "$CONTROL_PID" "$CA_PID" 2>/dev/null || true' TERM INT

exec mitmdump \
  --mode regular \
  --listen-port 8080 \
  --set confdir=/state/mitmproxy \
  --scripts /app/addons/quota_guard_addon.py \
  --set termlog_verbosity=info
