#!/usr/bin/env bash
# =============================================================================
# PrecisionIT — precisionit-mail (SMTP2GO) MCP connector installer (macOS / Linux)
# =============================================================================
# Installs the precisionit-mail MCP server and wires BOTH Claude Code
# (~/.claude.json) and Claude Desktop with machine-resolved absolute paths.
#
# Key sources:
#   keyvault (default) — SMTP2GO key pulled at runtime from Azure Key Vault via the
#                        per-user launcher under the tech's `az login`; the key
#                        never touches the config file.
#   static             — SMTP2GO key written into the config env (plaintext).
#
# The connector sends as MAIL_SENDER (the installing tech's address). That address
# MUST be on a domain verified in the PrecisionIT SMTP2GO account, or SMTP2GO
# rejects the send.
#
# Safe to re-run (idempotent): git pull + rewrites only the "precisionit-mail"
# server entry, leaving every other connector untouched.
#
# Required:
#   MAIL_SENDER="you@myprecisionit.com"
# Optional:
#   MAIL_KEY_SOURCE=keyvault|static          (default keyvault)
#   SMTP2GO_API_KEY=api-...                   (required only when MAIL_KEY_SOURCE=static)
#   MAIL_SECRET_SPEC="smtp2go-send-api-key:SMTP2GO_API_KEY"   (vault secret name : env var)
# =============================================================================
set -euo pipefail

REPO_URL="${PRECISIONIT_MAIL_REPO_URL:-https://github.com/dspray/precisionit-mail.git}"
INSTALL_ROOT="${PRECISIONIT_MAIL_HOME:-$HOME/Claude/mcp}"
KV_VAULT_RW_URL="${KV_VAULT_RW_URL:-https://PrecisionIT-MCP-RW.vault.azure.net/}"
KV_VAULT_RO_URL="${KV_VAULT_RO_URL:-https://PrecisionIT-MCP-RO.vault.azure.net/}"
# >>> CONFIRM this matches the real vault secret name holding the SMTP2GO key <<<
SECRET_SPEC="${MAIL_SECRET_SPEC:-smtp2go-send-api-key:SMTP2GO_API_KEY}"
KEY_SOURCE="${MAIL_KEY_SOURCE:-keyvault}"

say()  { printf '\033[1;34m[mail-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[mail-install] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[mail-install] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 0. Validate inputs -----------------------------------------------------
[ -n "${MAIL_SENDER:-}" ] || die "MAIL_SENDER is required, e.g. MAIL_SENDER=\"you@myprecisionit.com\" (must be a verified SMTP2GO sender)."
case "$KEY_SOURCE" in
  keyvault) ;;
  static)   [ -n "${SMTP2GO_API_KEY:-}" ] || die "MAIL_KEY_SOURCE=static requires SMTP2GO_API_KEY to be set." ;;
  *)        die "MAIL_KEY_SOURCE must be 'keyvault' or 'static', got '$KEY_SOURCE'." ;;
esac

# ---- 1. Prerequisites -------------------------------------------------------
say "Checking prerequisites…"
command -v git >/dev/null 2>&1 || die "git not found. Install Xcode CLT (mac) or your distro's git, then re-run."

NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || die "node not found on PATH. Install Node 18+ (brew install node / your distro), then re-run."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node $NODE_MAJOR found; precisionit-mail requires Node >=18."
say "node: $NODE_BIN (v$(node -p 'process.versions.node'))"

JQ_BIN="$(command -v jq || true)"

if [ "$KEY_SOURCE" = "keyvault" ]; then
  if command -v az >/dev/null 2>&1; then
    if az account show >/dev/null 2>&1; then
      say "az session: active ($(az account show --query user.name -o tsv 2>/dev/null || echo unknown))"
    else
      warn "az is installed but you are NOT logged in. Run 'az login' before the connector will work."
    fi
  else
    warn "Azure CLI (az) not found. Install it (brew install azure-cli) and run 'az login' before using the connector."
  fi
fi

# ---- 2. Clone or update -----------------------------------------------------
mkdir -p "$INSTALL_ROOT"
SRC_DIR="$INSTALL_ROOT/precisionit-mail"
if [ -d "$SRC_DIR/.git" ]; then
  say "Updating existing checkout at $SRC_DIR"
  git -C "$SRC_DIR" pull --ff-only
else
  say "Cloning $REPO_URL -> $SRC_DIR"
  git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

SERVER_JS="$SRC_DIR/server.js"
LAUNCHER_JS="$SRC_DIR/launcher/mcp-keyvault-launch.js"
[ -f "$SERVER_JS" ] || die "server not found at $SERVER_JS — repo layout unexpected."

# ---- 3. Dependencies --------------------------------------------------------
say "Installing server dependencies (npm ci)…"
( cd "$SRC_DIR" && npm ci --omit=dev --no-audit --no-fund )
if [ "$KEY_SOURCE" = "keyvault" ]; then
  [ -f "$LAUNCHER_JS" ] || die "launcher not found at $LAUNCHER_JS — add the launcher/ folder to the repo (copy it verbatim from claude-meraki-mcp)."
  say "Installing launcher dependencies (npm install)…"
  ( cd "$SRC_DIR/launcher" && npm install --omit=dev --no-audit --no-fund )
fi

# ---- 4. Build the server entry as JSON -------------------------------------
# Resolved absolute paths only — never the literal /usr/local/bin/node.
if [ "$KEY_SOURCE" = "keyvault" ]; then
  read -r -d '' ENTRY <<JSON || true
{
  "command": "$NODE_BIN",
  "args": ["$LAUNCHER_JS", "--secret", "$SECRET_SPEC", "--", "$NODE_BIN", "$SERVER_JS"],
  "env": {
    "KV_VAULT_RW_URL": "$KV_VAULT_RW_URL",
    "KV_VAULT_RO_URL": "$KV_VAULT_RO_URL",
    "MAIL_SENDER": "$MAIL_SENDER"
  }
}
JSON
else
  read -r -d '' ENTRY <<JSON || true
{
  "command": "$NODE_BIN",
  "args": ["$SERVER_JS"],
  "env": {
    "SMTP2GO_API_KEY": "$SMTP2GO_API_KEY",
    "MAIL_SENDER": "$MAIL_SENDER"
  }
}
JSON
fi

# ---- 5. Read-modify-write a config (preserves other connectors) ------------
wire_config() {
  local cfg="$1" label="$2"
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
  if [ -n "$JQ_BIN" ]; then
    local tmp; tmp="$(mktemp)"
    jq --argjson entry "$ENTRY" '.mcpServers = (.mcpServers // {}) | .mcpServers["precisionit-mail"] = $entry' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  else
    ENTRY_JSON="$ENTRY" CFG="$cfg" node -e '
      const fs=require("fs");
      const cfg=process.env.CFG;
      const entry=JSON.parse(process.env.ENTRY_JSON);
      const j=JSON.parse(fs.readFileSync(cfg,"utf8")||"{}");
      j.mcpServers=j.mcpServers||{}; j.mcpServers["precisionit-mail"]=entry;
      fs.writeFileSync(cfg, JSON.stringify(j,null,2));
    '
  fi
  say "Wired '$label' -> $cfg (backup saved)"
}

# Claude Code (user scope)
wire_config "$HOME/.claude.json" "Claude Code"

# Claude Desktop (macOS vs Linux path)
if [ "$(uname -s)" = "Darwin" ]; then
  wire_config "$HOME/Library/Application Support/Claude/claude_desktop_config.json" "Claude Desktop (macOS)"
else
  wire_config "$HOME/.config/Claude/claude_desktop_config.json" "Claude Desktop (Linux)"
fi

say "Install complete (key source: $KEY_SOURCE, sender: $MAIL_SENDER)."
if [ "$KEY_SOURCE" = "keyvault" ]; then
  say "NEXT: run 'az login' if you haven't, then fully restart Claude Desktop / reload Claude Code."
else
  say "NEXT: fully restart Claude Desktop / reload Claude Code."
fi
