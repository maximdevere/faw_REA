ARG BASE_IMAGE=ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
FROM ${BASE_IMAGE} AS downloads
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates python3 unzip xz-utils && rm -rf /var/lib/apt/lists/*
COPY versions.lock.json /build/versions.lock.json
COPY scripts/fetch-artifacts.py /build/fetch-artifacts.py
RUN python3 /build/fetch-artifacts.py --manifest /build/versions.lock.json --output /opt/artifacts --install-root /opt/tools

FROM ${BASE_IMAGE} AS fixtures
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*
COPY tests/fixtures/native.c /tmp/native.c
# Compile only: the fixture and targets are never executed.
RUN mkdir -p /fixtures && gcc -O0 -g -fno-inline -o /fixtures/native-fixture /tmp/native.c

FROM ${BASE_IMAGE} AS runtime
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="faw_REA static toolbox" \
      org.opencontainers.image.source="https://github.com/maximdevere/faw_REA" \
      org.opencontainers.image.revision=${VCS_REF} \
      org.opencontainers.image.version="0.1.0"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git procps util-linux file binutils ripgrep jq \
      unzip zip 7zip xz-utils python3 python3-venv \
      openjdk-21-jdk-headless libstdc++6 libgomp1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=downloads /opt/tools/node /opt/node
COPY --from=downloads /opt/tools/ghidra /opt/ghidra
COPY --from=downloads /opt/tools/jadx /opt/jadx
COPY --from=downloads /opt/tools/apktool /opt/apktool
ENV PATH="/opt/node/bin:/opt/rea/node_modules/.bin:${PATH}" \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    GHIDRA_INSTALL_DIR=/opt/ghidra \
    GHIDRA_HEADLESS_MAXMEM=2G \
    REA_ANALYSIS_PROVIDER=ghidra \
    REA_GHIDRA_STARTUP_TIMEOUT_MS=900000 \
    REA_JADX_MCP_JAR=/opt/jadx/jadx-headless-mcp-0.7.1-all.jar \
    REA_APKTOOL_COMMAND=/usr/local/bin/apktool \
    REA_MCP_INPUT_SCHEMA_PROFILE=compact \
    HOME=/home/rea \
    TMPDIR=/tmp \
    LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /opt/rea
COPY package.json package-lock.json ./
# No Frida or install scripts. The required Linux PTY addon is explicitly pinned.
RUN npm ci --omit=dev --omit=optional --ignore-scripts --no-fund --no-audit \
    && npm cache clean --force \
    && test ! -d node_modules/frida
COPY docker/apktool /usr/local/bin/apktool
COPY docker/entrypoint.sh /usr/local/bin/rea-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/rea-healthcheck
COPY scripts/smoke-mcp.py /opt/toolbox/smoke-mcp.py
COPY scripts/smoke-web.py /opt/toolbox/smoke-web.py
COPY scripts/mcp_client.py /opt/toolbox/mcp_client.py
COPY --from=fixtures /fixtures /opt/toolbox/fixtures
COPY versions.lock.json /opt/toolbox/versions.lock.json
RUN chmod 0644 /opt/jadx/*.jar /opt/apktool/*.jar \
    && chmod 0755 /usr/local/bin/apktool /usr/local/bin/rea-entrypoint /usr/local/bin/rea-healthcheck \
    && if getent passwd 1000 >/dev/null; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi \
    && if getent group 1000 >/dev/null; then groupdel "$(getent group 1000 | cut -d: -f1)"; fi \
    && groupadd --gid 1000 rea && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash rea \
    && mkdir -p /targets /uploads /work /results /home/rea/.cache \
    && chown -R rea:rea /targets /uploads /work /results /home/rea \
    && node --version && rea --version && apktool --version \
    && dpkg-query -W > /opt/toolbox/os-packages.txt \
    && npm ls --omit=dev --omit=optional --json > /opt/toolbox/npm-packages.json
COPY web /opt/toolbox/web
COPY config/opencode.example.json /opt/toolbox/web/opencode.example.json
USER rea
WORKDIR /work
EXPOSE 8787
HEALTHCHECK --interval=60s --timeout=15s --start-period=30s --retries=3 CMD ["/usr/local/bin/rea-healthcheck"]
ENTRYPOINT ["/usr/local/bin/rea-entrypoint"]
CMD ["python3", "/opt/toolbox/web/server.py", "--host", "0.0.0.0", "--port", "8787"]
