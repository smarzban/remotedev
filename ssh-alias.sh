#!/usr/bin/env bash
# =============================================================================
# ssh-alias.sh — add a local ~/.ssh/config alias for the Tailscale box.
#
# LOCAL helper: runs on YOUR machine, NOT the box (an SSH alias is a local
# artifact). It writes a `Host <name>` block so you can reach the box over
# Tailscale by name —
#     ssh <name>
#     ssh -t <name> 'sudo bash /root/<script>'
# instead of `ssh -t <user>@<tailscale-ip> -p <port> '…'`.
#
# The HostName is the box's Tailscale IP, resolved locally from THIS machine's
# tailnet view (`tailscale ip -4 <name>`) — no SSH into the box, no MagicDNS
# required. Idempotent: the block lives between sentinel markers and is rewritten
# in place, so re-run after a recreate to refresh the IP.
#
#   ./ssh-alias.sh                 # name/user/port from config.env (HCLOUD_SERVER_NAME, …)
#   ./ssh-alias.sh myhost          # override the alias/Host name
#   CHECK=1 ./ssh-alias.sh         # dry-run: show what would be written
#
# Requires: the box already bootstrapped/joined to the tailnet, and the
# `tailscale` CLI available here (PATH or the macOS Tailscale.app bundle).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
CHECK="${CHECK:-0}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Settings (positional arg / env / config.env override these defaults).
NAME="${1:-${SSH_ALIAS_NAME:-${HCLOUD_SERVER_NAME:-remotedev}}}"
TARGET_USER="${TARGET_USER:-deploy}"
SSH_PORT="${SSH_PORT:-2202}"
TS_HOSTNAME="${TS_HOSTNAME:-}"                       # tailnet name (defaults to NAME)
SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-$HOME/.ssh/config}"
LOOKUP="${TS_HOSTNAME:-$NAME}"

# --- output helpers (same vocabulary as the other scripts) -----------------
if [[ -t 1 ]]; then C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_Y=; C_R=; C_B=; C_0=; fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
changed() { printf '%s   ~%s %s\n' "$C_Y" "$C_0" "$*"; }
would() { printf '%s   ?%s would: %s\n' "$C_Y" "$C_0" "$*"; }

# Locate the tailscale CLI (PATH, or the macOS app bundle).
ts_bin() {
  command -v tailscale 2>/dev/null && return 0
  local app=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [[ -x "$app" ]] && { echo "$app"; return 0; }
  return 1
}

ts="$(ts_bin)" || die "tailscale CLI not found (PATH or Tailscale.app). Install it, then re-run."
ip="$("$ts" ip -4 "$LOOKUP" 2>/dev/null | head -1)"
[[ -n "$ip" ]] || die "'$LOOKUP' not on the tailnet — bootstrap/join the box first, then re-run."

begin="# >>> remotedev:$NAME (managed by ssh-alias.sh) >>>"
end="# <<< remotedev:$NAME <<<"

if [[ "$CHECK" == "1" ]]; then
  would "write SSH alias '$NAME' -> $ip (User $TARGET_USER, Port $SSH_PORT) in $SSH_CONFIG_FILE"
  exit 0
fi

mkdir -p "$(dirname "$SSH_CONFIG_FILE")"; chmod 700 "$(dirname "$SSH_CONFIG_FILE")" 2>/dev/null || true
# Drop any existing managed block for this name, then append a fresh one.
if [[ -f "$SSH_CONFIG_FILE" ]]; then
  awk -v b="$begin" -v e="$end" '$0==b{skip=1} skip!=1{print} $0==e{skip=0}' "$SSH_CONFIG_FILE" > "$SSH_CONFIG_FILE.tmp" \
    && mv "$SSH_CONFIG_FILE.tmp" "$SSH_CONFIG_FILE"
fi
{
  printf '%s\n' "$begin"
  printf 'Host %s\n    HostName %s\n    User %s\n    Port %s\n' "$NAME" "$ip" "$TARGET_USER" "$SSH_PORT"
  printf '%s\n' "$end"
} >> "$SSH_CONFIG_FILE"
chmod 600 "$SSH_CONFIG_FILE"

changed "SSH alias '$NAME' -> $ip in $SSH_CONFIG_FILE"
log "Now: ssh $NAME    (or: ssh -t $NAME 'sudo bash /root/<script>')"
