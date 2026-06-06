#!/usr/bin/env bash
# =============================================================================
# remotedev-bootstrap — reproduce a hardened, sealed security posture on a fresh VPS.
#
# Provider-agnostic. Idempotent: safe to re-run. Tested target: Ubuntu 22.04/24.04.
#
# Usage (run as root, or via sudo):
#   cp config.env.example config.env && edit config.env
#   sudo ./setup.sh                 # run everything
#   sudo ./setup.sh ssh firewall    # run only named steps
#   sudo CHECK=1 ./setup.sh         # dry-run: print what would change, change nothing
#
# Steps, in order: preflight user tailscale ssh fail2ban autoupgrades apparmor
#                  sysctl journald audit firewall
#
# SECURITY MODEL: the firewall's end-state allows inbound
# ONLY on tailscale0 — the public internet sees no open ports. To avoid locking
# ourselves out, the `firewall` step refuses to seal the box unless Tailscale is
# Running (or ALLOW_PUBLIC_SSH=true).
# =============================================================================
set -euo pipefail

# --- bootstrap: locate self, load config ----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
CHECK="${CHECK:-0}"   # CHECK=1 => dry run

if [[ -f "$CONFIG_FILE" ]]; then
  # NOTE: sourced WITHOUT `set -a` — config values (incl. SUDO_PASSWORD,
  # TS_AUTHKEY) stay shell-local and are NOT exported into child processes
  # (e.g. the piped Tailscale installer). The ${VAR:-default} pattern below
  # reads shell vars, so it works whether or not they were exported.
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Defaults (config.env / env vars override these)
TARGET_USER="${TARGET_USER:-deploy}"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"
SSH_PORT="${SSH_PORT:-2202}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-}"
ALLOW_PUBLIC_SSH="${ALLOW_PUBLIC_SSH:-false}"
ALLOW_SSH_FORWARDING="${ALLOW_SSH_FORWARDING:-false}"
LOCK_ROOT_PASSWORD="${LOCK_ROOT_PASSWORD:-true}"
INSTALL_AUDIT="${INSTALL_AUDIT:-false}"
SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-}"

ALL_STEPS=(preflight user tailscale ssh fail2ban autoupgrades apparmor sysctl journald audit firewall)

# --- output helpers --------------------------------------------------------
if [[ -t 1 ]]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_G=; C_Y=; C_R=; C_B=; C_0=; fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
changed() { printf '%s   ~%s %s\n' "$C_Y" "$C_0" "$*"; }
would() { printf '%s   ?%s would: %s\n' "$C_Y" "$C_0" "$*"; }

# run a mutating command, or just describe it under CHECK=1
do_run() { if [[ "$CHECK" == "1" ]]; then would "$*"; else eval "$*"; fi; }

# Write $2 to file $1 only if content differs. Honors CHECK. Returns 0 if changed.
write_file() {
  local path="$1" content="$2" mode="${3:-0644}"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
    ok "$path already current"; return 1
  fi
  if [[ "$CHECK" == "1" ]]; then would "write $path (mode $mode)"; return 0; fi
  install -D -m "$mode" /dev/null "$path"
  printf '%s\n' "$content" > "$path"
  changed "wrote $path"; return 0
}

# Tailscale backend state ("Running" when connected), empty if unavailable.
ts_backend_state() {
  tailscale status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1
}

# True if a usable SSH key will exist for TARGET_USER (from config or on disk).
has_ssh_key() {
  [[ -n "$(printf '%s' "$SSH_AUTHORIZED_KEYS" | tr -d '[:space:]')" ]] && return 0
  id "$TARGET_USER" &>/dev/null || return 1
  local home; home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -s "$home/.ssh/authorized_keys" ]]
}

apt_install() {
  local missing=()
  for p in "$@"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && { ok "packages present: $*"; return; }
  if [[ "$CHECK" == "1" ]]; then would "apt-get install ${missing[*]}"; return; fi
  log "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
}

# =============================================================================
# STEP: preflight
# =============================================================================
step_preflight() {
  [[ $EUID -eq 0 ]] || die "must run as root (use sudo)."
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] \
    || die "this script targets Ubuntu/Debian (found ID=$ID)."
  ok "OS: ${PRETTY_NAME:-$ID} ($(uname -m))"
  command -v systemctl >/dev/null || die "systemd required."

  # Fail-fast: refuse to start a run that can't finish for lack of an SSH key,
  # BEFORE the tailscale step consumes a (possibly single-use) auth key.
  if [[ "$ALLOW_PUBLIC_SSH" != "true" ]] && ! has_ssh_key; then
    die "No SSH key available for '$TARGET_USER': set SSH_AUTHORIZED_KEYS in config.env \
(or give the user an authorized_keys file) before running. Refusing to start so a single-use \
Tailscale auth key isn't wasted on a run that would abort at the 'ssh' step. \
Override with ALLOW_PUBLIC_SSH=true."
  fi

  # Warn about the common sudo env-reset pitfall: secrets passed as env vars are
  # stripped unless `sudo -E` is used; only config.env survives env_reset.
  if [[ -n "${SUDO_USER:-}" && -z "$SUDO_PASSWORD" && -z "$TS_AUTHKEY" && ! -f "$CONFIG_FILE" ]]; then
    warn "Running under sudo with no config.env and no SUDO_PASSWORD/TS_AUTHKEY. \
If you passed them as env vars, sudo stripped them — use 'sudo -E' or put them in config.env."
  fi

  if [[ "$CHECK" != "1" ]]; then
    log "apt-get update"; apt-get update -q
  fi
  apt_install ca-certificates curl ufw
}

# =============================================================================
# STEP: user — create the non-root sudo user + install authorized keys
# =============================================================================
step_user() {
  if id "$TARGET_USER" &>/dev/null; then
    ok "user '$TARGET_USER' exists"
  else
    do_run "adduser --disabled-password --gecos '' '$TARGET_USER'"
    changed "created user '$TARGET_USER'"
  fi
  if id -nG "$TARGET_USER" 2>/dev/null | grep -qw sudo; then
    ok "'$TARGET_USER' already in sudo group"
  else
    do_run "usermod -aG sudo '$TARGET_USER'"
    changed "added '$TARGET_USER' to sudo"
  fi

  # Password — this posture requires a password for sudo, so the user needs one.
  # Idempotent: only set if the account has no usable password yet (status != P).
  local pwstatus; pwstatus="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')"
  if [[ "$pwstatus" == "P" ]]; then
    ok "'$TARGET_USER' already has a password set"
  elif [[ "$CHECK" == "1" ]]; then
    would "set password for '$TARGET_USER'"
  else
    local pw="$SUDO_PASSWORD"
    if [[ -z "$pw" ]]; then
      if [[ -t 0 ]]; then
        read -r -s -p "Set password for '$TARGET_USER': " pw; echo
        local pw2; read -r -s -p "Confirm password: " pw2; echo
        [[ "$pw" == "$pw2" ]] || die "passwords did not match."
      else
        die "no SUDO_PASSWORD set and no interactive terminal to prompt. \
Set SUDO_PASSWORD in config.env (it's git-ignored) and re-run."
      fi
    fi
    [[ -z "$pw" ]] && die "empty password; aborting."
    printf '%s:%s\n' "$TARGET_USER" "$pw" | chpasswd
    unset pw
    changed "set password for '$TARGET_USER'"
  fi

  # Authorized keys
  local home akf
  home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  akf="$home/.ssh/authorized_keys"
  local keys; keys="$(printf '%s\n' "$SSH_AUTHORIZED_KEYS" | sed '/^[[:space:]]*$/d')"
  if [[ -n "$keys" ]]; then
    local merged existing=""
    [[ -f "$akf" ]] && existing="$(cat "$akf")"
    merged="$(printf '%s\n%s\n' "$existing" "$keys" | sed '/^[[:space:]]*$/d' | sort -u)"
    if [[ "$CHECK" != "1" ]]; then
      install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$home/.ssh"
      printf '%s\n' "$merged" > "$akf"
      chown "$TARGET_USER:$TARGET_USER" "$akf"; chmod 600 "$akf"
      changed "installed authorized_keys for '$TARGET_USER'"
    else would "merge authorized_keys for '$TARGET_USER'"; fi
  elif [[ -s "$akf" ]]; then
    ok "keeping existing authorized_keys for '$TARGET_USER'"
  else
    warn "no SSH_AUTHORIZED_KEYS set and '$TARGET_USER' has no keys — \
the 'ssh' step will refuse to disable password auth to avoid lockout."
  fi

  # Lock the root password (defense-in-depth for serial/rescue console).
  # Only after the target user has a working key, so we never strand the box.
  # SSH root login is already disabled separately (PermitRootLogin no).
  if [[ "$LOCK_ROOT_PASSWORD" == "true" ]]; then
    if has_ssh_key; then
      local rootpw; rootpw="$(passwd -S root 2>/dev/null | awk '{print $2}')"
      if [[ "$rootpw" == "L" ]]; then
        ok "root password already locked"
      else
        do_run "passwd -l root"
        changed "locked root password"
      fi
    else
      warn "not locking root password yet — '$TARGET_USER' has no SSH key."
    fi
  fi
}

# =============================================================================
# STEP: tailscale — install + join the tailnet (TUN mode, no exit node/routes)
# =============================================================================
step_tailscale() {
  if ! command -v tailscale &>/dev/null; then
    if [[ "$CHECK" == "1" ]]; then would "install tailscale via pkgs.tailscale.com";
    else log "installing Tailscale"; curl -fsSL https://tailscale.com/install.sh | sh; fi
  else ok "tailscale installed ($(tailscale version 2>/dev/null | head -1))"; fi

  do_run "systemctl enable --now tailscaled"

  local state=""
  command -v tailscale &>/dev/null && state="$(ts_backend_state)" || true
  if [[ "$state" == "Running" ]]; then
    ok "Tailscale already Running ($(tailscale ip -4 2>/dev/null | head -1))"
    # Reconcile posture drift (no re-auth needed): no exit node, no advertised
    # routes, and Tailscale SSH OFF (it would be an auth path bypassing sshd).
    do_run "tailscale set --advertise-exit-node=false --advertise-routes= --ssh=false --accept-routes=false"
    return
  fi
  if [[ -z "$TS_AUTHKEY" ]]; then
    if [[ "$ALLOW_PUBLIC_SSH" == "true" ]]; then
      warn "no TS_AUTHKEY and ALLOW_PUBLIC_SSH=true — skipping tailnet join."
      return
    fi
    die "Tailscale not connected and TS_AUTHKEY is empty. Set TS_AUTHKEY in config.env \
(generate at https://login.tailscale.com/admin/settings/keys), or set ALLOW_PUBLIC_SSH=true."
  fi

  # Build args as an array; pass the auth key via a 0600 tmpfs file (file:PATH)
  # so it never appears in the process argv (ps / /proc/<pid>/cmdline).
  local up_args=(--ssh=false --accept-routes=false)
  [[ -n "$TS_HOSTNAME" ]] && up_args+=(--hostname="$TS_HOSTNAME")
  if [[ "$CHECK" == "1" ]]; then
    would "tailscale up --authkey=file:<tmpfile> ${up_args[*]}"
    return
  fi
  local keyfile; keyfile="$(mktemp /run/remotedev-ts.key.XXXXXX 2>/dev/null || mktemp)"
  chmod 600 "$keyfile"
  # shellcheck disable=SC2064
  trap "shred -u '$keyfile' 2>/dev/null || rm -f '$keyfile'" RETURN
  printf '%s' "$TS_AUTHKEY" > "$keyfile"
  tailscale up --authkey="file:$keyfile" "${up_args[@]}"
  unset TS_AUTHKEY
  ok "joined tailnet ($(tailscale ip -4 2>/dev/null | head -1))"
}

# =============================================================================
# STEP: ssh — harden sshd via a drop-in (idempotent, validated before reload)
# =============================================================================
step_ssh() {
  apt_install openssh-server

  # Anti-lockout: never disable password auth if TARGET_USER has no key.
  local home akf; home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; akf="$home/.ssh/authorized_keys"
  if [[ ! -s "$akf" ]] && [[ -z "$(printf '%s' "$SSH_AUTHORIZED_KEYS" | tr -d '[:space:]')" ]]; then
    die "Refusing to harden SSH: '$TARGET_USER' has no authorized_keys. \
Set SSH_AUTHORIZED_KEYS and re-run the 'user' step first."
  fi

  local fwd="no"; [[ "$ALLOW_SSH_FORWARDING" == "true" ]] && fwd="yes"
  local conf="/etc/ssh/sshd_config.d/99-remotedev-hardening.conf"
  local content="# Managed by remotedev-bootstrap — SSH hardening.
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
UsePAM yes
X11Forwarding no
AllowTcpForwarding ${fwd}
AllowAgentForwarding ${fwd}
PermitTunnel no
AllowGroups sudo
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2"
  write_file "$conf" "$content" 0644 || true

  if [[ "$CHECK" == "1" ]]; then
    would "sshd -t; fix ssh.socket if active; reload/restart ssh; assert listening on ${SSH_PORT}"
    return
  fi
  sshd -t || die "sshd config test failed — NOT reloading (existing sshd untouched)."

  # On socket-activated systems (some 24.04 setups), the sshd_config Port is
  # IGNORED — ssh.socket owns the listening port. Override the socket too.
  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    warn "ssh.socket is active — Port directive alone is ignored; overriding the socket."
    install -D -m 0644 /dev/null /etc/systemd/system/ssh.socket.d/override.conf
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT" \
      > /etc/systemd/system/ssh.socket.d/override.conf
    systemctl daemon-reload
    systemctl restart ssh.socket
  fi
  systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd

  # Assert sshd is actually listening on the new port BEFORE the firewall seals
  # the box — a silent wrong-port bind would otherwise look like success.
  if ! ss -tlnH "( sport = :$SSH_PORT )" 2>/dev/null | grep -q . ; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    sleep 1
    ss -tlnH "( sport = :$SSH_PORT )" 2>/dev/null | grep -q . \
      || die "sshd is NOT listening on port ${SSH_PORT} after reload — aborting before the firewall seals the box. Check 'journalctl -u ssh'."
  fi
  ok "sshd hardened and listening on port $SSH_PORT"

  # Interim-window notice: between this step and the firewall step (or after a
  # partial run), a hardened-but-PUBLIC sshd is reachable on $SSH_PORT.
  if [[ "$ALLOW_PUBLIC_SSH" != "true" ]] && ! ufw status 2>/dev/null | grep -qi 'Status: active'; then
    warn "sshd is key-only but the firewall is not yet active — port $SSH_PORT is reachable \
publicly until the 'firewall' step runs. Keep a provider security group in place during bootstrap."
  fi
}

# =============================================================================
# STEP: fail2ban — nftables banaction, systemd backend, sshd jail
# =============================================================================
step_fail2ban() {
  apt_install fail2ban
  local content="# Managed by remotedev-bootstrap — fail2ban configuration.
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}"
  if write_file /etc/fail2ban/jail.local "$content" 0644; then
    do_run "systemctl enable --now fail2ban"
    do_run "systemctl restart fail2ban"
  else
    do_run "systemctl enable --now fail2ban"
  fi
  ok "fail2ban configured"
}

# =============================================================================
# STEP: autoupgrades — unattended-upgrades with the reference allowed-origins
# =============================================================================
step_autoupgrades() {
  apt_install unattended-upgrades
  write_file /etc/apt/apt.conf.d/20auto-upgrades \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' 0644 || true
  write_file /etc/apt/apt.conf.d/52remotedev-origins \
'Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::DevRelease "auto";' 0644 || true
  do_run "systemctl enable --now unattended-upgrades"
  ok "unattended-upgrades enabled"
}

# =============================================================================
# STEP: apparmor — ensure enabled
# =============================================================================
step_apparmor() {
  apt_install apparmor
  do_run "systemctl enable --now apparmor"
  ok "apparmor enabled"
}

# =============================================================================
# STEP: sysctl — kernel/network hardening. Deliberately does NOT touch
#   ip_forward / forwarding sysctls — tailscaled manages those.
# =============================================================================
step_sysctl() {
  local content="# Managed by remotedev-bootstrap — kernel/network hardening.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1"
  if write_file /etc/sysctl.d/99-remotedev-hardening.conf "$content" 0644; then
    do_run "sysctl --system >/dev/null"
  fi
  ok "sysctl hardening applied"
}

# =============================================================================
# STEP: journald — persistent logs so fail2ban/audit history survives reboot
#   (fail2ban uses backend=systemd; a volatile journal loses ban history).
# =============================================================================
step_journald() {
  local content="# Managed by remotedev-bootstrap — persistent logs for forensics.
[Journal]
Storage=persistent
SystemMaxUse=500M"
  if write_file /etc/systemd/journald.conf.d/99-remotedev.conf "$content" 0644; then
    do_run "systemctl restart systemd-journald"
  fi
  ok "journald persistent storage configured"
}

# =============================================================================
# STEP: audit — OPT-IN (INSTALL_AUDIT=true) detection layer: auditd with a
#   low-noise auth/identity ruleset. Off by default (minimal reference posture).
# =============================================================================
step_audit() {
  if [[ "$INSTALL_AUDIT" != "true" ]]; then
    ok "audit step skipped (set INSTALL_AUDIT=true to enable auditd)"
    return
  fi
  apt_install auditd audispd-plugins
  local content="# Managed by remotedev-bootstrap — low-noise auth/identity audit rules.
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /var/log/auth.log -p wa -k authlog"
  if write_file /etc/audit/rules.d/99-remotedev.rules "$content" 0640; then
    do_run "augenrules --load 2>/dev/null || systemctl restart auditd"
  fi
  do_run "systemctl enable --now auditd"
  ok "auditd configured (opt-in detection layer)"
}

# =============================================================================
# STEP: firewall — UFW: deny in / allow out, allow ONLY tailscale0 (+ optional public SSH)
#   This is the lockout-sensitive step, so it runs last and guards itself.
# =============================================================================
step_firewall() {
  apt_install ufw

  # Anti-lockout guard ----------------------------------------------------
  local ts_state="" sess_src="" on_tailscale="unknown"
  command -v tailscale &>/dev/null && ts_state="$(ts_backend_state)" || true
  # Determine the source address of THIS ssh session. Prefer $SSH_CONNECTION,
  # but fall back to parsing the established sshd connection (sudo strips
  # SSH_CONNECTION without -E), so the guard isn't silently disabled.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    sess_src="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
  else
    # sudo strips SSH_CONNECTION without -E. Fall back to utmp (who am i shows
    # the login from-host), then to the peer of the established sshd socket.
    sess_src="$(who am i 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')"
    [[ -z "$sess_src" ]] && sess_src="$(ss -tnH state established "( sport = :22 or sport = :$SSH_PORT )" 2>/dev/null \
      | awk '{print $5}' | sed 's/:[0-9]*$//; s/^\[//; s/\]$//' \
      | grep -vE '^(127\.|::1$)' | head -1)"
  fi
  # Tailscale CGNAT is 100.64.0.0/10 (100.64–100.127.x.x), or v6 fd7a:115c:a1e0::/48.
  if [[ -n "$sess_src" ]]; then
    if [[ "$sess_src" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] \
       || [[ "$sess_src" == fd7a:115c:a1e0:* ]]; then on_tailscale=1; else on_tailscale=0; fi
  fi
  if [[ "$ALLOW_PUBLIC_SSH" != "true" ]]; then
    [[ "$ts_state" == "Running" ]] || die "Refusing to seal firewall: Tailscale is not Running \
(state='${ts_state:-none}'). Bring it up (run the 'tailscale' step) or set ALLOW_PUBLIC_SSH=true."
    if [[ "$on_tailscale" == "0" ]]; then
      warn "You appear to be connected over a NON-Tailscale address ($sess_src). Sealing the \
firewall will drop this session. Reconnect over Tailscale first, or set ALLOW_PUBLIC_SSH=true."
      [[ "$CHECK" == "1" ]] || die "aborting to prevent lockout."
    elif [[ "$on_tailscale" == "unknown" ]]; then
      warn "Could not determine this session's source address; relying on the Tailscale-Running \
gate. If you are on a non-Tailscale link this may drop your session."
    fi
  fi

  # Seal IPv6 too: UFW only emits ip6tables rules when IPV6=yes in
  # /etc/default/ufw. Without this, a public IPv6 sshd on :: stays exposed.
  if [[ -f /etc/default/ufw ]] && ! grep -q '^IPV6=yes' /etc/default/ufw; then
    if [[ "$CHECK" == "1" ]]; then would "set IPV6=yes in /etc/default/ufw";
    else sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; \
      grep -q '^IPV6=' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw; \
      changed "enabled IPv6 in /etc/default/ufw"; fi
  else
    ok "UFW IPv6 already enabled"
  fi

  # Base policy -----------------------------------------------------------
  do_run "ufw --force default deny incoming"
  do_run "ufw --force default allow outgoing"
  do_run "ufw --force default deny routed"
  do_run "ufw logging low"

  # Allow all inbound on the tailscale interface (the access path; v4 + v6) -
  do_run "ufw allow in on tailscale0"

  # Optional public SSH fallback -----------------------------------------
  if [[ "$ALLOW_PUBLIC_SSH" == "true" ]]; then
    do_run "ufw allow ${SSH_PORT}/tcp"
    warn "ALLOW_PUBLIC_SSH=true — SSH port ${SSH_PORT} is OPEN on the public interface."
  else
    # Ensure no stray public SSH rule lingers from a prior run
    do_run "ufw --force delete allow ${SSH_PORT}/tcp 2>/dev/null || true"
  fi

  do_run "ufw --force enable"
  [[ "$CHECK" == "1" ]] || { log "ufw status:"; ufw status verbose; }
}

# =============================================================================
# runner
# =============================================================================
main() {
  local steps=("$@")
  [[ ${#steps[@]} -eq 0 ]] && steps=("${ALL_STEPS[@]}")
  [[ "$CHECK" == "1" ]] && warn "CHECK=1 dry-run — no changes will be made."
  for s in "${steps[@]}"; do
    local fn="step_${s}"
    declare -F "$fn" >/dev/null || die "unknown step '$s' (valid: ${ALL_STEPS[*]})"
    log "STEP: $s"
    "$fn"
  done
  log "done."
  [[ "$ALLOW_PUBLIC_SSH" != "true" ]] && command -v tailscale &>/dev/null && \
    echo "Reach this box at: ssh -p ${SSH_PORT} ${TARGET_USER}@$(tailscale ip -4 2>/dev/null | head -1)"
}
main "$@"
