#!/usr/bin/env bash
#
# wd-claude-setup.sh
#
# Configure Claude Code on this machine to:
#   - always default to the latest Opus generation  ("model": "opus")
#   - start every session in auto mode               ("defaultMode": "auto")
#   - make auto mode available on gateway/Bedrock/Vertex/Foundry sessions
#     ("env": {"CLAUDE_CODE_ENABLE_AUTO_MODE": "1"})
#
# Idempotent: deep-merges these keys into ~/.claude/settings.json WITHOUT
# clobbering any other settings you already have (allow rules, theme, etc.).
# Safe to run repeatedly and to push across the fleet (GW1/GW2/WD10/WD20/WD30).
#
# Honors $CLAUDE_CONFIG_DIR if you've relocated the config dir.
#
# Usage:   ./wd-claude-setup.sh
#

set -euo pipefail

AUTO_MIN_VERSION="2.1.83"    # minimum for auto mode to exist at all
ENV_MIN_VERSION="2.1.158"   # minimum for CLAUDE_CODE_ENABLE_AUTO_MODE

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

# A >= B  using version sort
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

echo "Claude Code setup — $(hostname)"
echo

# --- version check (non-fatal) ---------------------------------------------
if command -v claude >/dev/null 2>&1; then
  VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ -z "$VER" ]; then
    warn "Could not parse 'claude --version'; skipping version check."
  elif ver_ge "$VER" "$ENV_MIN_VERSION"; then
    ok "claude $VER  (auto mode + enable-var fully supported)"
  elif ver_ge "$VER" "$AUTO_MIN_VERSION"; then
    warn "claude $VER  — auto mode works, but CLAUDE_CODE_ENABLE_AUTO_MODE needs >= $ENV_MIN_VERSION."
    warn "On gateway/Bedrock/Vertex sessions auto may not appear until you update Claude Code."
  else
    warn "claude $VER  — too old for auto mode (needs >= $AUTO_MIN_VERSION). Update before relying on this."
  fi
else
  warn "'claude' not found on PATH; writing settings anyway."
fi

# --- read existing settings -------------------------------------------------
mkdir -p "$CONFIG_DIR"

SRC="{}"
if [ -f "$SETTINGS" ] && [ -s "$SETTINGS" ]; then
  SRC="$(cat "$SETTINGS")"
  [ -n "${SRC//[[:space:]]/}" ] || SRC="{}"
  BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$SETTINGS" "$BACKUP"
  ok "Backed up existing settings -> $BACKUP"
fi

PATCH='{"model":"opus","permissions":{"defaultMode":"auto"},"env":{"CLAUDE_CODE_ENABLE_AUTO_MODE":"1"}}'

# --- deep-merge with jq, falling back to python3 ----------------------------
merged=""
if command -v jq >/dev/null 2>&1; then
  if ! merged="$(printf '%s' "$SRC" | jq --argjson patch "$PATCH" '. * $patch' 2>/dev/null)"; then
    err "Existing $SETTINGS is not valid JSON. Fix or remove it, then re-run."
    exit 1
  fi
elif command -v python3 >/dev/null 2>&1; then
  if ! merged="$(SRC="$SRC" PATCH="$PATCH" python3 - <<'PY'
import json, os, sys
def deep_merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            deep_merge(a[k], v)
        else:
            a[k] = v
    return a
try:
    src = json.loads(os.environ["SRC"] or "{}")
except json.JSONDecodeError as e:
    sys.stderr.write("invalid JSON: %s\n" % e); sys.exit(1)
print(json.dumps(deep_merge(src, json.loads(os.environ["PATCH"])), indent=2))
PY
)"; then
    err "Existing $SETTINGS is not valid JSON. Fix or remove it, then re-run."
    exit 1
  fi
else
  err "Need 'jq' or 'python3' to merge JSON safely."
  err "Install one (e.g. sudo apt-get install -y jq) and re-run."
  exit 1
fi

# --- write atomically -------------------------------------------------------
TMP="$(mktemp "$CONFIG_DIR/.settings.XXXXXX")"
printf '%s\n' "$merged" > "$TMP"
mv "$TMP" "$SETTINGS"
ok "Wrote $SETTINGS"

echo
echo "Effective settings:"
sed 's/^/    /' "$SETTINGS"
echo
echo "Next: restart any running 'claude' sessions, then run /status to confirm"
echo "model = Opus and mode = auto. (Settings are read at startup, not mid-session.)"
