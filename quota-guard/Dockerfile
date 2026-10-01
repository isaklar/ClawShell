FROM python:3.12-slim

# Stdlib-only control API + mitmproxy (ecosystem tool, not reinvented) for the
# egress allowlist / circuit-breaker addon. No unnecessary dependencies.
RUN pip install --no-cache-dir mitmproxy==11.* \
    && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin quotaguard

WORKDIR /app
COPY addons/ /app/addons/
COPY control_api.py /app/control_api.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh \
    && mkdir -p /state /logs /allowlist.d /config \
    && chown -R quotaguard:quotaguard /app /state /logs /allowlist.d /config

USER quotaguard
EXPOSE 8080
# Control API (8088) is intentionally NOT exposed/published — loopback/container-
# network only, consumed by pentest-task.sh and healthcheck.sh from inside the
# same Docker network.

ENTRYPOINT ["/app/entrypoint.sh"]
