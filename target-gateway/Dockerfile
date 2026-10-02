FROM python:3.12-slim

# Stdlib-only control API + mitmproxy (ecosystem tool, not reinvented) for the
# black-box live-testing egress boundary: per-engagement scope allowlist, rate
# limiting, approval gating, and local evidence logging for TARGET traffic.
# Separate component from quota-guard; shares no state or logic with it.
RUN pip install --no-cache-dir mitmproxy==11.* \
    && useradd --uid 10002 --no-create-home --shell /usr/sbin/nologin targetgw

WORKDIR /app
COPY addons/ /app/addons/
COPY control_api.py /app/control_api.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh \
    && mkdir -p /state /logs /scope \
    && chown -R targetgw:targetgw /app /state /logs /scope

USER targetgw
EXPOSE 8080
# Control API (8089) is intentionally NOT exposed/published — container-network
# only, consumed by pentest-task.sh and scope.sh from inside the same network.

ENTRYPOINT ["/app/entrypoint.sh"]
