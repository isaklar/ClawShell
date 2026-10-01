#!/bin/sh
# caveman-proxy entrypoint.
#
# Verified behavior this relies on (docs/technical/cli-reference.md,
# docs/technical/proxy-and-providers.md in JuliusBrussee/caveman):
#   - `caveman start` runs the standalone loopback HTTP proxy, default
#     127.0.0.1:8787, config at $HOME/.caveman/caveman.yaml, local data at
#     $HOME/.caveman/caveman.db.
#   - The proxy refuses non-loopback listen addresses — which is exactly why
#     this container uses `network_mode: "service:openclaw-gateway"` in
#     compose/compose.yml: it shares the Gateway's network namespace so
#     "loopback" for one is loopback for both, instead of needing a routable
#     address.
#   - Named OpenAI-compatible upstreams are configured via a `compat` mount
#     in caveman.yaml (`base_url` + `api_key_env`), routed at
#     /compat/<name>/...
#
# This only wires up the `custom` (OpenAI-compatible) MODEL_PROVIDER path —
# see docs/caveman-integration.md for why the official Anthropic/OpenAI
# provider plugins are out of scope (no verified baseURL override for them).
set -eu

if [ -n "${CAVEMAN_UPSTREAM_API_KEY_FILE:-}" ] && [ -f "${CAVEMAN_UPSTREAM_API_KEY_FILE}" ]; then
  CAVEMAN_UPSTREAM_API_KEY="$(cat "${CAVEMAN_UPSTREAM_API_KEY_FILE}")"
  export CAVEMAN_UPSTREAM_API_KEY
else
  echo "caveman-proxy: CAVEMAN_UPSTREAM_API_KEY_FILE is not set or unreadable." >&2
  exit 1
fi

if [ -z "${CAVEMAN_UPSTREAM_BASE_URL:-}" ]; then
  echo "caveman-proxy: CAVEMAN_UPSTREAM_BASE_URL is not set." >&2
  echo "Set it to the real upstream OpenAI-compatible endpoint (what" >&2
  echo "MODEL_PROVIDER_BASE_URL pointed at before enabling the proxy)." >&2
  echo "See docs/caveman-integration.md before enabling CAVEMAN_PROXY_ENABLED." >&2
  exit 1
fi

mkdir -p "${HOME}/.caveman"
cat > "${HOME}/.caveman/caveman.yaml" <<EOF
compat:
  upstream:
    base_url: ${CAVEMAN_UPSTREAM_BASE_URL}
    api_key_env: CAVEMAN_UPSTREAM_API_KEY
EOF

echo "caveman-proxy: starting, upstream=${CAVEMAN_UPSTREAM_BASE_URL}, listen=127.0.0.1:8787 (shared with openclaw-gateway)"
exec caveman start
