FROM node:22-alpine

# @caveman-ai/cli — verified: https://github.com/JuliusBrussee/caveman
# (MIT CLI, BSL-1.1 proxy runtime; self-hosted first-party use is free, see
# docs/caveman-integration.md). Baked in at build time so the running
# container never needs npm-registry/GitHub-releases egress.
#
# `caveman start` is a thin wrapper around a separate signed `caveman-proxy`
# Go binary that npm alone doesn't install — `caveman setup --install`
# fetches it (verified: running `caveman start` without it fails with an
# explicit "Couldn't find caveman-proxy on your PATH or in ~/.caveman/bin").
# Installed under /opt/caveman (HOME overridden just for this RUN step),
# deliberately NOT under the "node" user's real $HOME, because $HOME/.caveman
# is where compose.yml mounts the persistent state volume at runtime — a
# volume mount there would otherwise hide these baked-in binaries.
# CAVEMAN_PROXY_BIN/CAVEMAN_ENGINE_BIN (documented env overrides) point the
# CLI at them regardless of $HOME.
RUN npm install -g @caveman-ai/cli@2.0.0 \
    && mkdir -p /opt/caveman \
    && HOME=/opt/caveman caveman setup --install \
    && chmod -R a+rX /opt/caveman

ENV CAVEMAN_PROXY_BIN=/opt/caveman/.caveman/bin/caveman-proxy
ENV CAVEMAN_ENGINE_BIN=/opt/caveman/.caveman/bin/caveman-engine

COPY entrypoint.sh /usr/local/bin/caveman-proxy-entrypoint.sh
RUN chmod +x /usr/local/bin/caveman-proxy-entrypoint.sh

USER node
WORKDIR /home/node
ENV HOME=/home/node

ENTRYPOINT ["/usr/local/bin/caveman-proxy-entrypoint.sh"]
