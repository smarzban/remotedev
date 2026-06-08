#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — scrub the provisioning artifacts this toolkit copied onto a box.
#
# Run this LAST, once the box is hardened (setup.sh), verified (verify.sh), and
# tooled (tooling.sh). It removes everything we copied over so nothing sensitive
# or unnecessary lingers:
#   - config.env        SHREDDED (holds SUDO_PASSWORD + the Tailscale auth key)
#   - *.log             setup.sh / tooling.sh run logs
#   - setup.sh verify.sh tooling.sh   the scripts themselves
#   - cleanup.sh        this script, removed last
#
# It only touches its OWN directory and only the known toolkit files (allow-list)
# — never arbitrary files. Idempotent: re-running is a no-op.
#
#   ./cleanup.sh           # scrub artifacts in this directory
#   CHECK=1 ./cleanup.sh   # dry run: show what would be removed, remove nothing
#
# Note: leaves the hardened box itself untouched (users, firewall, sshd, tools).
# After this you'd re-copy the scripts if you ever need to re-run them.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CHECK:-0}"
SELF="$(basename "${BASH_SOURCE[0]}")"

# --- output helpers (same vocabulary as setup.sh / tooling.sh) -------------
if [[ -t 1 ]]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_G=; C_Y=; C_B=; C_0=; fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
changed() { printf '%s   ~%s %s\n' "$C_Y" "$C_0" "$*"; }
would() { printf '%s   ?%s would: %s\n' "$C_Y" "$C_0" "$*"; }

# Files holding secrets — overwrite (shred) before unlinking.
SECRET_FILES=(config.env)
# The toolkit scripts to remove (literal allow-list; logs handled via glob below).
SCRIPT_FILES=(setup.sh verify.sh tooling.sh)

[[ "$CHECK" == "1" ]] && warn "CHECK=1 dry-run — nothing will be removed."

shred_file() { # shred a secret-bearing file if present
  local p="$SCRIPT_DIR/$1"
  [[ -e "$p" ]] || { ok "absent: $1"; return; }
  if [[ "$CHECK" == "1" ]]; then would "shred -u $1"; return; fi
  if shred -u "$p" 2>/dev/null; then changed "shredded $1"
  else rm -f "$p"; warn "shred unavailable — removed $1 (not securely overwritten)"; fi
}

remove_file() { # unlink an artifact if present
  local p="$1"
  [[ -e "$p" ]] || return
  if [[ "$CHECK" == "1" ]]; then would "rm $(basename "$p")"; return; fi
  rm -f "$p"; changed "removed $(basename "$p")"
}

log "scrubbing provisioning artifacts in $SCRIPT_DIR"

# 1) Secrets first.
for f in "${SECRET_FILES[@]}"; do shred_file "$f"; done

# 2) Run logs (glob over SCRIPT_DIR; nullglob so no match = no-op).
shopt -s nullglob
for p in "$SCRIPT_DIR"/*.log; do remove_file "$p"; done
shopt -u nullglob

# 3) The toolkit scripts (literal allow-list; never $SELF here).
for f in "${SCRIPT_FILES[@]}"; do
  [[ "$f" == "$SELF" ]] && continue
  remove_file "$SCRIPT_DIR/$f"
done

# 4) Finally, remove this script itself. (The running shell is already loaded
#    into memory, so unlinking $0 mid-run is safe on Linux.)
if [[ "$CHECK" == "1" ]]; then
  would "rm $SELF (self)"
else
  log "done — removing $SELF"
  rm -f "$SCRIPT_DIR/$SELF"
  echo
  log "All done — the box is hardened, sealed, verified, tooled, and scrubbed. 🎉"
  echo
  log "Tip — on your LOCAL machine, run ./ssh-alias.sh to add an 'ssh <name>' shortcut over Tailscale."
fi