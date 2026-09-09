#!/usr/bin/env bash
# setup.sh — one-command bootstrap for the OpenCode Telegram Startup Chain.
#
# Provisions everything a fresh clone needs so the chain runs without hunting
# down missing pieces: it fetches a REAL Node binary (the assistant image only
# ships a Bun shim masquerading as `node`), installs the OpenCode CLI, installs
# the @grinev/opencode-telegram-bot bridge, applies the pinned-message patch,
# collects the three vault secrets, deploys the launchers + init hook, and
# launches the supervisor.
#
# Idempotent: safe to re-run. See INSTALL.md for the full rationale.
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Paths (all hard-coded to match the launcher scripts / boot hook)
# ---------------------------------------------------------------------------
WORKSPACE="${WORKSPACE:-/workspace}"
REPO="${REPO:-$WORKSPACE/opencode-telegram-startup}"
BIN_DIR="$WORKSPACE/bin"
HOOKS_DIR="$WORKSPACE/hooks"
OPENCODE_BIN="$WORKSPACE/.opencode/bin/opencode"
NODE_BIN="$WORKSPACE/runtime/node/bin/node"
NPMCLI="$WORKSPACE/runtime/node/lib/node_modules/npm/bin/npm-cli.js"
BRIDGE_DIR="$WORKSPACE/runtime/opencode-telegram-bot"
DATA_DIR="$WORKSPACE/data/opencode-telegram"
NODE_VERSION="${NODE_VERSION:-v24.3.0}"
ARCH="$(uname -m)"

# ---------------------------------------------------------------------------
# 1. Fetch a REAL Node (the image's /usr/local/bin/node is a Bun shim)
# ---------------------------------------------------------------------------
need_real_node() {
  [ -x "$NODE_BIN" ] || return 0
  local napi
  napi="$("$NODE_BIN" -e 'console.log(process.versions.napi)' 2>/dev/null || true)"
  # The Bun shim reports napi undefined / a junk version. Real Node 22.14+ has N-API 10.
  [ "$napi" = "10" ]
}

if need_real_node; then
  echo ">> Fetching real Node.js $NODE_VERSION (the image's 'node' is a Bun shim)..."
  case "$ARCH" in
    x86_64)  NDED="linux-x64" ;;
    aarch64|arm64) NDED="linux-arm64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
  esac
  rm -rf "$WORKSPACE/runtime/node" "$WORKSPACE/runtime/node.tar.xz"
  mkdir -p "$WORKSPACE/runtime/node/bin"
  curl -fsSL -o /tmp/node.tar.xz \
    "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-${NDED}.tar.xz"
  tar -xJf /tmp/node.tar.xz -C /tmp
  cp "/tmp/node-${NODE_VERSION}-${NDED}/bin/node" "$NODE_BIN"
  mkdir -p "$WORKSPACE/runtime/node/lib"
  cp -rf "/tmp/node-${NODE_VERSION}-${NDED}/lib/node_modules" "$WORKSPACE/runtime/node/lib/"
  chmod +x "$NODE_BIN"
  rm -rf /tmp/node.tar.xz "/tmp/node-${NODE_VERSION}-${NDED}"
  echo ">> real node: $("$NODE_BIN" --version) (N-API $("$NODE_BIN" -e 'console.log(process.versions.napi)'))"
else
  echo ">> Real Node already present: $("$NODE_BIN" --version)"
fi

# ---------------------------------------------------------------------------
# 2. Install the OpenCode CLI (copy out of /data so it survives cache pruning)
# ---------------------------------------------------------------------------
if [ ! -x "$OPENCODE_BIN" ]; then
  echo ">> Installing OpenCode CLI..."
  curl -fsSL https://opencode.ai/install | bash || true
  if [ -x /data/.opencode/bin/opencode ]; then
    mkdir -p "$WORKSPACE/.opencode/bin"
    cp -f /data/.opencode/bin/opencode "$OPENCODE_BIN"
    chmod +x "$OPENCODE_BIN"
  fi
  [ -x "$OPENCODE_BIN" ] || { echo "OpenCode install failed"; exit 1; }
  echo ">> opencode: $("$OPENCODE_BIN" --version)"
else
  echo ">> OpenCode already present: $("$OPENCODE_BIN" --version)"
fi

# ---------------------------------------------------------------------------
# 3. Install the bridge package, then apply the pinned-message patch
# ---------------------------------------------------------------------------
if [ ! -f "$BRIDGE_DIR/node_modules/@grinev/opencode-telegram-bot/dist/cli.js" ]; then
  echo ">> Installing @grinev/opencode-telegram-bot (bun)..."
  mkdir -p "$BRIDGE_DIR"
  cd "$BRIDGE_DIR"
  [ -f package.json ] || echo '{"name":"opencode-telegram-bot-runtime","private":true}' > package.json
  # NOTE: the better-sqlite3 postinstall may fail with "node-gyp: command not
  # found". That is expected — the prebuilt linux addon is used instead.
  bun install @grinev/opencode-telegram-bot || true
  # Rebuild the native addon against real Node so Node-API v10 prebuilds are used.
  "$NODE_BIN" "$NPMCLI" rebuild better-sqlite3 || true
fi

# Always (re)apply the unpin patch after an install — it is NOT in the package.
echo ">> Applying pinned-message patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-unpin-fix.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# Always (re)apply the session-recovery patch (auto-recreates a session when
# the OpenCode server restarts and wipes its session store) — NOT in the package.
echo ">> Applying session-recovery patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-session-recovery.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# Always (re)apply the keep-session-on-stop patch (refuses to kill the server
# while a session exists, so /opencode_stop can't wipe the conversation) — NOT in the package.
echo ">> Applying keep-session-on-stop patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-keep-session-on-stop.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# Add /opencode_restart, which gracefully restarts only the Telegram bridge.
# The supervisor relaunches it while the OpenCode server and session stay alive.
echo ">> Applying safe-restart-command patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-safe-restart-command.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# Restart upgrade: /opencode_restart edits its message to "✅ Restarted." after
# the relaunch, the Telegram "/" menu is force-refreshed on every boot, and the
# unsafe /opencode_start and /opencode_stop commands are removed entirely
# (the supervisor owns the server lifecycle).
echo ">> Applying restart-upgrade patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-restart-upgrade.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# Delete-session command: /delete_session lists sessions in an inline keyboard
# (same style as /sessions); tapping one asks "Are you sure?" with Yes/No
# buttons; Yes deletes the session (and its messages) from the OpenCode DB via
# the SDK, No cancels. Deleting the active session clears the bridge's session
# state so the next prompt creates a fresh one.
echo ">> Applying delete-session-command patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-delete-session-command.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# Compaction-level command: /compaction_level shows an inline keyboard of
# context-window fill percentages (50-90%); picking one computes the matching
# compaction.reserved token budget for the current model, applies it live to
# the running OpenCode server via PATCH /config (no restart), and persists it
# to the server's opencode.jsonc so it survives restarts.
echo ">> Applying compaction-level patch..."
patch -p1 -d "$WORKSPACE" --forward --silent < "$REPO/patches/opencode-telegram-bot-compaction-level.patch" \
  || echo "   (patch already applied or no-op — continuing)"

# ---------------------------------------------------------------------------
# 4. Collect vault secrets (never in chat; secure prompts)
# ---------------------------------------------------------------------------
ask_cred() { # service field label description
  if assistant credentials reveal --service "$1" --field "$2" >/dev/null 2>&1; then
    echo ">> vault already has $1/$2 — skipping"
  else
    echo ">> Opening secure prompt for $1/$2"
    assistant credentials prompt --service "$1" --field "$2" \
      --label "$3" --description "$4"
  fi
}

ask_cred opencode_proxy server_password "OpenCode Server Password" \
  "Password that secures the localhost OpenCode server (127.0.0.1:4096). You choose it."
ask_cred opencode api_key "OpenCode API Key" \
  "API key OpenCode uses to reach its model provider."
ask_cred telegram bot_token "Telegram Bot Token" \
  "Token from @BotFather for the bridge bot."

# Confirm the allowed Telegram user ID is the owner's
if ! assistant credentials reveal --service telegram --field bot_token >/dev/null 2>&1; then
  echo ">> Set TELEGRAM_ALLOWED_USER_ID in bin/opencode-telegram-bridge to the owner's numeric Telegram user id."
fi

# ---------------------------------------------------------------------------
# 5. Deploy the launchers + init hook into the workspace
# ---------------------------------------------------------------------------
echo ">> Deploying launchers and init hook..."
mkdir -p "$BIN_DIR" "$HOOKS_DIR" "$DATA_DIR"/{run,logs}
for f in opencode-telegram-supervise opencode-telegram-server \
         opencode-telegram-bridge opencode-telegram-restart clean-data-caches.sh; do
  cp -f "$REPO/bin/$f" "$BIN_DIR/$f"
done
chmod +x "$BIN_DIR"/*
cp -f "$REPO/hooks/init.ts" "$HOOKS_DIR/init.ts"

# ---------------------------------------------------------------------------
# 6. Launch the supervisor (idempotent; safe on every boot)
# ---------------------------------------------------------------------------
echo ">> Launching supervisor..."
setsid nohup "$BIN_DIR/opencode-telegram-supervise" \
  >> "$DATA_DIR/logs/supervisor.log" 2>&1 < /dev/null &

echo ""
echo "Setup complete. Watch it come up:"
echo "  tail -f $DATA_DIR/logs/supervisor.log       # expect 'OK: server healthy, bridge running' every 15s"
echo "  tail -f $DATA_DIR/logs/telegram-bridge.log  # expect 'Bot @... started!'"
echo ""
echo "Bot must be reachable at: your Telegram bot, allowed user ID set in bin/opencode-telegram-bridge."
