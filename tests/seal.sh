#!/usr/bin/env bash
# tests/seal.sh — live test of the firewall seal on a DISPOSABLE host (CI VM or a
# privileged container). It enables ufw. Tailscale is stubbed as "Running" so the
# anti-lockout gate passes; the real gate is covered by the refusal case below.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest ci"
fail() { echo "FAIL: $*"; exit 1; }
added() { ufw show added | grep '^ufw ' || true; }

ufw --force reset >/dev/null
ufw allow 22/tcp comment 'provider ssh' >/dev/null
ufw allow from 192.168.1.0/24 >/dev/null
ufw allow 2202/tcp >/dev/null
ufw limit 80/tcp >/dev/null

# 1. Without Tailscale the seal must refuse and change nothing.
stub=/usr/local/bin/tailscale
[[ -e "$stub" ]] && fail "$stub exists — run this on a disposable host only"
if bash "$ROOT/setup.sh" firewall >/dev/null 2>&1; then fail "sealed without Tailscale"; fi
[[ "$(added | wc -l)" -eq 4 ]] || fail "refused seal still changed rules"

# 2. With Tailscale "Running": strays removed, only tailscale0 left, verify agrees.
printf '#!/bin/sh\n[ "$1" = status ] && echo '"'"'{"BackendState": "Running"}'"'"'\nexit 0\n' > "$stub"
chmod +x "$stub"; trap 'rm -f "$stub"' EXIT
bash "$ROOT/setup.sh" firewall
[[ "$(added)" == "ufw allow in on tailscale0" ]] || { added; fail "strays survived the seal"; }
out="$(bash "$ROOT/verify.sh" 2>/dev/null || true)"
grep -q 'PASS no allow rules except tailscale0' <<<"$out" || fail "verify rejected a clean seal"

# 3. verify catches a stray added after the seal.
ufw allow 8080/tcp >/dev/null
# Capture first: `verify | grep -q` + pipefail = SIGPIPE false failure (see CLAUDE.md).
out="$(bash "$ROOT/verify.sh" 2>/dev/null || true)"
grep -q 'FAIL no allow rules except tailscale0' <<<"$out" || fail "verify missed a stray"

# 4. Re-run is idempotent; public-SSH mode keeps exactly the SSH port.
ufw delete allow 8080/tcp >/dev/null
out="$(bash "$ROOT/setup.sh" firewall)"; grep -q 'stray' <<<"$out" && fail "re-run found strays"
ufw allow 9999/tcp >/dev/null
ALLOW_PUBLIC_SSH=true bash "$ROOT/setup.sh" firewall >/dev/null
[[ "$(added | sort)" == "$(printf 'ufw allow 2202/tcp\nufw allow in on tailscale0')" ]] || { added; fail "public-SSH mode"; }
echo "PASS: seal removes strays, refuses without Tailscale, verify agrees"
