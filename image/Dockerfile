# hutch base image: the coding agents and an unprivileged user that has the host user's ids.
# A project image adds its toolchain on top (template/Dockerfile: FROM ${HUTCH_BASE}).
FROM node:24.21.0-bookworm AS base

# opencode CLI, the default agent: the glibc release asset, pinned by sha256. Add a line per architecture you use;
# a missing one fails the build instead of installing an unchecked binary.
FROM base AS opencode
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in \
      arm64) asset=opencode-linux-arm64.tar.gz; sum=f2d27600c367e45057d6a16f6a5c2aa8d77b41a9b10d4bc3d849c2f88870e944 ;; \
      amd64) asset=opencode-linux-x64.tar.gz; sum=08bb21d6326ce740d91cce7ebe88a6536933f6e1e30353b91a06b01f25da306c ;; \
      *) echo "hutch: no pinned opencode v2.2.6 sha256 for $TARGETARCH; add it to image/Dockerfile" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/oc.tgz "https://github.com/anomalyco/opencode/releases/download/v2.2.6/$asset"; \
    echo "$sum  /tmp/oc.tgz" | sha256sum -c -; \
    tar -xzf /tmp/oc.tgz -C /usr/local/bin opencode; \
    /usr/local/bin/opencode --version

FROM base
ARG HUTCH_UID=1000
ARG HUTCH_GID=1000
RUN npm install -g @anthropic-ai/claude-code@2.1.318 && npm cache clean --force
COPY --from=opencode /usr/local/bin/opencode /usr/local/bin/opencode
# The agent's home directories are created and owned here: a volume mounted over a missing one is root-owned, and the
# agents then fail with EACCES. /cache is the default place for a project's persistent cache volume.
RUN groupadd -o -g "$HUTCH_GID" hutch && useradd -m -o -u "$HUTCH_UID" -g "$HUTCH_GID" -s /bin/bash hutch \
 && mkdir -p /work /out /task /cache \
    /home/hutch/.local/share/opencode /home/hutch/.local/state /home/hutch/.config/opencode /home/hutch/.cache /home/hutch/.claude \
 && chown hutch /work /out /task /cache && chown -R hutch /home/hutch
ENV DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1
USER hutch
WORKDIR /work
