#!/usr/bin/env bash
# Entrypoint for the AOS container.
#
# On first start (empty state volume) this initialises the Community Edition
# distro, then runs the kernel in the foreground so the container's lifecycle
# is the daemon's lifecycle. On subsequent starts the existing state volume is
# reused and initialisation is skipped.
set -euo pipefail

DISTRO_DIR=/opt/aos-distro
STATE="${ASTRID_HOME:-$HOME/.astrid}"  # runtime state volume

# Secrets arrive through the environment, never through the image or argv.
: "${OPENAI_API_KEY:=}"
: "${OPENAI_BASE_URL:=https://api.openai.com}"
: "${OPENAI_MODEL:=gpt-5.4}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_ALLOWED_USER_IDS:=}"

# `astrid init` is itself idempotent — it compares the distro against the state
# volume and reports "already installed" without touching anything. We therefore
# do NOT guard it with our own marker file: the Distro.lock lives in a per-project
# workspace dir beside Distro.toml (ephemeral, inside the image layer), not in
# the state volume, so any guard based on it would be wrong on every restart.
init_distro() {
  if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "!! OPENAI_API_KEY is not set. The provider capsule will install but" >&2
    echo "!! the agent cannot answer until it is configured." >&2
  fi
  echo "==> Initialising Unicity AOS Community Edition..."
  # `source` paths in Distro.toml resolve relative to the working directory.
  cd "$DISTRO_DIR"
  astrid init \
    --distro Distro.toml \
    --yes \
    --allow-unsigned \
    --var "openai_api_key=$OPENAI_API_KEY" \
    --var "openai_base_url=$OPENAI_BASE_URL" \
    --var "openai_model=$OPENAI_MODEL"

  cd "$HOME"
}

# The Telegram uplink ships outside the CE distro, so it is installed
# separately. This runs on EVERY start, not just first init: the token can be
# added or rotated on an existing state volume, and `capsule install` is
# idempotent (it content-addresses the artifact and rewrites the env config).
ensure_telegram() {
  if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    echo "==> No TELEGRAM_BOT_TOKEN set — skipping the Telegram uplink."
    return
  fi
  if [[ -z "$TELEGRAM_ALLOWED_USER_IDS" ]]; then
    echo "!! TELEGRAM_ALLOWED_USER_IDS is empty — ANY Telegram user will be" >&2
    echo "!! able to drive this agent." >&2
  fi
  # Built from unicity-aos/capsule-telegram at image build time; the commit it
  # came from is recorded alongside it.
  if [[ -f "$DISTRO_DIR/telegram-commit.txt" ]]; then
    echo "==> Telegram uplink from upstream commit $(cat "$DISTRO_DIR/telegram-commit.txt")"
  fi
  echo "==> Installing/updating the Telegram uplink capsule..."
  ASTRID_VAR_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  ASTRID_VAR_ALLOWED_USER_IDS="$TELEGRAM_ALLOWED_USER_IDS" \
    astrid capsule install "$DISTRO_DIR/capsules/astrid-capsule-telegram.capsule" --yes
}

case "${1:-daemon}" in
  daemon)
    init_distro
    ensure_telegram
    echo "==> Starting Astrid kernel (foreground)..."
    exec astrid-daemon
    ;;
  init)
    init_distro
    ensure_telegram
    ;;
  shell)
    exec /bin/bash
    ;;
  *)
    # Anything else is passed straight through to the astrid CLI, so
    # `docker exec <ctr> entrypoint.sh status` and friends work.
    exec astrid "$@"
    ;;
esac
