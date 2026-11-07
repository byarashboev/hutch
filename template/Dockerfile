# Project image: hutch-base plus this project's toolchain, with dependency caches warmed so the sandbox works offline.
# The build context holds src/: the files the config's manifests= matches, at their repository paths.
ARG HUTCH_BASE=hutch-base:latest
FROM ${HUTCH_BASE}
USER root
# Install the toolchain here, pinned to the versions the project uses. Examples:
#   COPY --from=golang:<version>-bookworm /usr/local/go /usr/local/go
#   RUN apt-get update && apt-get install -y --no-install-recommends python3-venv && rm -rf /var/lib/apt/lists/*
# Warm dependency caches from the manifests, for example:
#   WORKDIR /src
#   COPY src/ ./
#   RUN npm ci
# Then make offline the default, for example: ENV npm_config_offline=true
USER hutch
WORKDIR /work
