# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# uv is pulled from its official image: multi-arch, pinnable, no curl | sh.
# ---------------------------------------------------------------------------
ARG UV_VERSION=0.9.7
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM node:24.15.0-bookworm

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG OPENCODE_VERSION=latest
ARG PYTHON_VERSION=3.14
ARG HADOLINT_VERSION=2.12.0
# Asset naming changed to lowercase (glab_X_linux_amd64.deb) in later 1.x
# releases; older tags used Linux_x86_64. Check before downgrading this pin.
ARG GLAB_VERSION=1.85.3
# TARGETARCH is populated automatically by buildx.
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Base OS tooling: VCS, SSH, linters, and the shell utilities agents reach for.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-client \
        jq \
        less \
        make \
        ripgrep \
        fd-find \
        shellcheck \
        build-essential \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Docker CLI + compose v2 plugin. CLI only, no daemon: mount the host socket
# with -v /var/run/docker.sock:/var/run/docker.sock at runtime.
# ---------------------------------------------------------------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
         -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
        docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# GitHub CLI, from the official apt repo (amd64 + arm64).
# ---------------------------------------------------------------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# GitLab CLI. No official apt repo, so pull the release .deb. GitLab's arch
# suffixes (amd64/arm64) match TARGETARCH directly.
# ---------------------------------------------------------------------------
RUN curl -fsSL -o /tmp/glab.deb \
        "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${TARGETARCH}.deb" \
    && dpkg -i /tmp/glab.deb \
    && rm -f /tmp/glab.deb

# ---------------------------------------------------------------------------
# hadolint: single static binary, published for amd64 and arm64.
# ---------------------------------------------------------------------------
RUN case "${TARGETARCH}" in \
        amd64) hadolint_arch="x86_64" ;; \
        arm64) hadolint_arch="arm64" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/hadolint \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${hadolint_arch}" \
    && chmod 0755 /usr/local/bin/hadolint \
    && hadolint --version

# ---------------------------------------------------------------------------
# Python toolchain via uv. Interpreters land in a world-readable /opt so the
# non-root opencode user can use them; without UV_PYTHON_INSTALL_DIR they
# would go to /root/.local and be unreadable.
# ---------------------------------------------------------------------------
COPY --from=uv /uv /uvx /usr/local/bin/

ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_LINK_MODE=copy

RUN uv python install "${PYTHON_VERSION}" \
    && uv tool install ruff \
    && chmod -R a+rX /opt/uv

# ---------------------------------------------------------------------------
# opencode itself. Kept late: it changes far more often than anything above,
# so every release rebuild reuses the toolchain layers.
# ---------------------------------------------------------------------------
RUN npm i -g "opencode-ai@${OPENCODE_VERSION}" && \
    installed_version_raw="$(opencode --version)" && \
    installed_version="${installed_version_raw#v}" && \
    echo "Installed opencode version: ${installed_version}" && \
    if [ "${OPENCODE_VERSION}" != "latest" ] && [ "${installed_version}" != "${OPENCODE_VERSION}" ]; then \
        echo "Expected opencode version ${OPENCODE_VERSION}, got ${installed_version}" >&2; \
        exit 1; \
    fi

# ---------------------------------------------------------------------------
# Unprivileged user.
# ---------------------------------------------------------------------------
RUN adduser --disabled-password --gecos "" opencode \
    && mkdir -p /home/opencode/.local/share/opencode \
                /home/opencode/.local/state/opencode \
                /home/opencode/.config/opencode \
                /home/opencode/.cache/uv \
                /workspace \
    && chown -R opencode:opencode /home/opencode /workspace

ENV UV_CACHE_DIR=/home/opencode/.cache/uv

# ---------------------------------------------------------------------------
# Fail the build loudly if any tool is missing or broken.
# ---------------------------------------------------------------------------
RUN set -euo pipefail; \
    git --version; \
    ssh -V; \
    docker --version; \
    docker compose version; \
    gh --version; \
    glab --version; \
    hadolint --version; \
    shellcheck --version; \
    uv --version; \
    uv python find "${PYTHON_VERSION}"; \
    ruff --version; \
    jq --version; \
    rg --version

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096"]
