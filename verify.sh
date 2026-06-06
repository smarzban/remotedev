#!/usr/bin/env bash
# =============================================================================
# verify.sh — read-only audit that the hardened security posture is in place.
# Run on the target box; sudo is REQUIRED for full firewall/sshd/fail2ban/audit
# detail (without it, several checks cannot read the truth and will fail).
#   sudo ./verify.sh
# Exits non-zero if any check fails.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/config.env" ]] && . "$SCRIPT_DIR/config.env"
SSH_PORT="${SSH_PORT:-2202}"
TARGET_USER="${TARGET_USER:-deploy}"
ALLOW_PUBLIC_SSH="${ALLOW_PUBLIC_SSH:-false}"
LOCK_ROOT_PASSWORD="${LOCK_ROOT_PASSWORD:-true}"
INSTALL_AUDIT="${INSTALL_AUDIT:-false}"

[[ $EUID -eq 0 ]] || echo "WARNING: not running as root — firewall/sshd checks may be incomplete." >&2

pass=0 fail=0
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Z=$'\e[0m'; else G=; R=; Z=; fi
chk() { # chk "desc" "command..."
  local desc="$1"; shift
  if eval "$*" &>/dev/null; then printf '%s PASS%s %s\n' "$G" "$Z" "$desc"; ((pass++))
  else printf '%s FAIL%s %s\n' "$R" "$Z" "$desc"; ((fail++)); fi
}

echo "== SSH =="
chk "sshd listening on port $SSH_PORT"        "ss -tlnH '( sport = :$SSH_PORT )' | grep -q ."
chk "root login disabled"                     "sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'"
chk "password auth disabled"                  "sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'"
chk "pubkey auth enabled"                     "sshd -T 2>/dev/null | grep -qx 'pubkeyauthentication yes'"
chk "MaxAuthTries = 3"                         "sshd -T 2>/dev/null | grep -qx 'maxauthtries 3'"
chk "TCP forwarding disabled"                 "sshd -T 2>/dev/null | grep -qx 'allowtcpforwarding no'"
chk "access limited to sudo group"            "sshd -T 2>/dev/null | grep -qix 'allowgroups sudo'"

echo "== Firewall (sealed posture) =="
chk "ufw active"                              "ufw status 2>/dev/null | grep -qi 'Status: active'"
chk "default deny incoming"                   "ufw status verbose 2>/dev/null | grep -qi 'deny (incoming)'"
chk "default deny routed"                     "ufw status verbose 2>/dev/null | grep -qi 'deny (routed)'"
chk "IPv6 enabled in ufw"                     "grep -q '^IPV6=yes' /etc/default/ufw"
chk "allow in on tailscale0 (v4)"             "ufw status 2>/dev/null | grep -Ei 'Anywhere +on tailscale0 +ALLOW'"
chk "allow in on tailscale0 (v6)"             "ufw status 2>/dev/null | grep -Ei 'Anywhere \\(v6\\) on tailscale0 +ALLOW'"
# The crown jewel: no PUBLIC allow rule for the SSH port (unless explicitly opted in).
if [[ "$ALLOW_PUBLIC_SSH" == "true" ]]; then
  chk "public SSH allow present (opt-in)"     "ufw status 2>/dev/null | grep -Eq '^$SSH_PORT(/tcp)? +ALLOW'"
else
  chk "NO public SSH port rule"               "! ufw status 2>/dev/null | grep -Eq '^$SSH_PORT(/tcp)? +ALLOW +Anywhere'"
fi

echo "== Tailscale =="
chk "tailscaled active"                       "systemctl is-active --quiet tailscaled"
chk "backend Running"                         "tailscale status --json 2>/dev/null | grep -q '\"BackendState\": *\"Running\"'"
chk "not advertising as exit node"            "! tailscale status --json 2>/dev/null | grep -q '\"ExitNodeOption\": *true'"

echo "== fail2ban =="
chk "fail2ban active"                          "systemctl is-active --quiet fail2ban"
chk "sshd jail present"                        "fail2ban-client status sshd"

echo "== Auto-updates / AppArmor =="
chk "unattended-upgrades enabled"             "systemctl is-enabled --quiet unattended-upgrades"
chk "apparmor active"                          "systemctl is-active --quiet apparmor"

echo "== Kernel / logging hardening =="
chk "kptr_restrict = 2"                        "sysctl -n kernel.kptr_restrict 2>/dev/null | grep -qx 2"
chk "tcp_syncookies = 1"                       "sysctl -n net.ipv4.tcp_syncookies 2>/dev/null | grep -qx 1"
chk "rp_filter = 1"                            "sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null | grep -qx 1"
chk "journald persistent storage"             "test -d /var/log/journal"

echo "== Accounts =="
chk "user '$TARGET_USER' exists"               "id '$TARGET_USER'"
chk "'$TARGET_USER' in sudo group"             "id -nG '$TARGET_USER' | grep -qw sudo"
[[ "$LOCK_ROOT_PASSWORD" == "true" ]] && \
  chk "root password locked"                   "passwd -S root 2>/dev/null | awk '{print \$2}' | grep -qx L"

if [[ "$INSTALL_AUDIT" == "true" ]]; then
  echo "== Audit (opt-in) =="
  chk "auditd active"                          "systemctl is-active --quiet auditd"
  chk "remotedev audit rules loaded"           "auditctl -l 2>/dev/null | grep -q identity"
fi

echo
echo "Passed: $pass  Failed: $fail"
[[ $fail -eq 0 ]]
