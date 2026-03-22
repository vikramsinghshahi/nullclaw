#!/bin/sh
# Set up SSH deploy key from env so the bot can run `git push` over SSH.
# Then exec nullclaw gateway (or whatever CMD is).
set -eu

SSH_DIR="${HOME:-/nullclaw-data}/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519"
CONFIG_FILE="$SSH_DIR/config"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ -n "${GIT_SSH_KEY_B64:-}" ]; then
  echo "$GIT_SSH_KEY_B64" | base64 -d > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
elif [ -n "${GIT_SSH_KEY:-}" ]; then
  printf '%s' "$GIT_SSH_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi

if [ -f "$KEY_FILE" ]; then
  printf 'Host github.com\n  IdentityFile %s\n  StrictHostKeyChecking accept-new\n' "$KEY_FILE" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
fi

exec nullclaw "$@"
