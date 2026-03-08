# syntax=docker/dockerfile:1

# ── Stage 1: Build ────────────────────────────────────────────
# Build natively on the runner architecture and cross-compile per TARGETARCH.
FROM --platform=$BUILDPLATFORM alpine:3.23 AS builder

RUN apk add --no-cache zig musl-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY vendor/sqlite3/ vendor/sqlite3/

ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall

# ── Stage 2: Config Prep ─────────────────────────────────────
# This stage bakes a minimal, non-secret default config into the image.
# You can later override it by building your own image with a different config
# or by mounting a volume at /nullclaw-data/.nullclaw.
# Primary model set to deepseek-chat (cheaper); use /model in Telegram to switch if needed.
FROM busybox:1.37 AS config

RUN mkdir -p /nullclaw-data/.nullclaw /nullclaw-data/workspace

RUN cat > /nullclaw-data/.nullclaw/config.json << 'EOF'
{
  "default_temperature": 0.7,
  "models": {
    "providers": {
      "openrouter": {}
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/deepseek/deepseek-chat",
        "fallback": "openrouter/openai/gpt-4o-mini"
      }
    }
  },
  "agent": {
    "max_tool_iterations": 3
  },
  "channels": {
    "cli": true,
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "8661978832:AAF4eyspgR3GVIX2iA1P2JvNl_7X7ssvwYk",
          "allow_from": ["yana_akam"],
          "reply_in_private": true
        }
      }
    }
  },
  "memory": {
    "backend": "markdown",
    "auto_save": true
  },
  "autonomy": {
    "level": "full",
    "workspace_only": true,
    "allowed_commands": ["git", "git *", "ls", "cat", "echo", "pwd", "mkdir", "mv", "cp"],
    "allowed_paths": ["/nullclaw-data/workspace"]
  },
  "gateway": {
    "port": 3000,
    "host": "::",
    "allow_public_bind": true
  }
}
EOF

# Default runtime runs as non-root (uid/gid 65534).
# Keep writable ownership for HOME/workspace in safe mode.
RUN chown -R 65534:65534 /nullclaw-data

# ── Stage 3: Runtime Base (shared) ────────────────────────────
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullclaw

RUN apk add --no-cache ca-certificates curl tzdata git openssh-client

COPY --from=builder /app/zig-out/bin/nullclaw /usr/local/bin/nullclaw
COPY --from=config /nullclaw-data /nullclaw-data
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Git identity for bot commits (git config is blocked by security policy; set here so commits work)
RUN printf '[user]\nname = nullclaw-bot\nemail = bot@nullclaw.local\n' > /nullclaw-data/.gitconfig && chown 65534:65534 /nullclaw-data/.gitconfig

ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV HOME=/nullclaw-data
ENV NULLCLAW_GATEWAY_PORT=3000

WORKDIR /nullclaw-data
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["gateway", "--port", "3000", "--host", "::"]

# Optional autonomous mode (explicit opt-in):
#   docker build --target release-root -t nullclaw:root .
FROM release-base AS release-root
USER 0:0

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534
