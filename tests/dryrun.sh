#!/usr/bin/env bash
# tests/dryrun.sh — the CHECK=1 contract: every script's full dry run exits 0 on a
# fresh box and changes nothing. Run as root inside a throwaway Ubuntu/Debian
# container (CI does this; for the local Docker one-liner see CLAUDE.md → Tests).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CHECK=1 SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest ci"

# Snapshot what a dry run must not touch.
snap() { find /etc /usr/local /home /root -xdev -newer "$1" -type f 2>/dev/null | grep -v '^/root/\.' || true; }
marker="$(mktemp)"; sleep 1

run() { echo "::group::$*"; "$@"; echo "::endgroup::"; }
run bash "$ROOT/setup.sh"
run bash "$ROOT/tooling.sh"
work="$(mktemp -d)"; cp "$ROOT"/{setup,verify,tooling,cleanup}.sh "$work/"
run bash "$work/cleanup.sh"
[[ -f "$work/cleanup.sh" && -f "$work/setup.sh" ]] || { echo "FAIL: cleanup dry run removed files"; exit 1; }

changed="$(snap "$marker")"
if [[ -n "$changed" ]]; then echo "FAIL: dry run modified files:"; echo "$changed"; exit 1; fi
id deploy &>/dev/null && { echo "FAIL: dry run created the target user"; exit 1; }
echo "PASS: dry runs exited 0 and changed nothing"
