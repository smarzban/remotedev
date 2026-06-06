#!/usr/bin/env bash
# =============================================================================
# tooling.sh — day-0 dev-host bring-up for a box already hardened by setup.sh.
#
# This is the DEV-TOOLING layer, kept deliberately separate from the security
# core in setup.sh. Run setup.sh FIRST (it creates TARGET_USER, seals the box,
# joins the tailnet); then run this to make the box useful for development.
#
# Provider-agnostic. Idempotent: safe to re-run. Target: Ubuntu 22.04/24.04.
#
# Usage (run as root, or via sudo):
#   sudo ./tooling.sh                  # run everything (respecting toggles)
#   sudo ./tooling.sh docker uv        # run only named steps
#   sudo CHECK=1 ./tooling.sh          # dry-run: print what would change, change nothing
#
# Steps, in order: upgrade docker brew uv python
#   upgrade  full `apt-get dist-upgrade` (setup.sh only does `update`, never upgrade)
#   docker   Docker CE from Docker's signed apt repo + adds TARGET_USER to docker group
#   brew     Homebrew (Linuxbrew), installed AS TARGET_USER (never as root)
#   uv       Astral uv, installed AS TARGET_USER (standalone installer)
#   python   system Python base (python3 + venv + pip + dev); uv manages extra versions
# =============================================================================
set -euo pipefail

# --- bootstrap: locate self, load config (shared with setup.sh) ------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
CHECK="${CHECK:-0}"   # CHECK=1 => dry run

if [[ -f "$CONFIG_FILE" ]]; then
  # Sourced WITHOUT `set -a` — values stay shell-local, never exported to children.
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Defaults (config.env / env vars override these)
TARGET_USER="${TARGET_USER:-deploy}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_BREW="${INSTALL_BREW:-true}"
INSTALL_UV="${INSTALL_UV:-true}"
INSTALL_PYTHON="${INSTALL_PYTHON:-true}"

ALL_STEPS=(upgrade docker brew uv python)

# --- output helpers (same vocabulary as setup.sh) --------------------------
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

# install apt packages only if missing (honors CHECK)
apt_install() {
  local missing=()
  for p in "$@"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
  [[ ${#missing[@]} -eq 0 ]] && { ok "packages present: $*"; return; }
  if [[ "$CHECK" == "1" ]]; then would "apt-get install ${missing[*]}"; return; fi
  log "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
}

# Run a command AS TARGET_USER with a login-ish env (-H sets HOME). Honors CHECK.
as_user() {
  if [[ "$CHECK" == "1" ]]; then would "as $TARGET_USER: $*"; return 0; fi
  sudo -u "$TARGET_USER" -H bash -c "$*"
}

# These steps operate on TARGET_USER's account — it must already exist.
require_user() {
  id "$TARGET_USER" &>/dev/null \
    || die "user '$TARGET_USER' does not exist. Run setup.sh first: 'sudo ./setup.sh user'."
}

user_home() { getent passwd "$TARGET_USER" | cut -d: -f6; }

# Append $1 (a fixed line) to a TARGET_USER-owned rc file $2 if not already present.
add_user_line() {
  local line="$1" file="$2" match="${3:-$1}"
  if [[ "$CHECK" == "1" ]]; then would "ensure line in $file: $line"; return; fi
  touch "$file"; chown "$TARGET_USER:$TARGET_USER" "$file"
  grep -qF "$match" "$file" || { printf '\n%s\n' "$line" >> "$file"; changed "updated $file"; }
}

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)."
command -v apt-get >/dev/null || die "this script targets Debian/Ubuntu (apt-get not found)."

# =============================================================================
# STEP: upgrade — the full `apt-get dist-upgrade` that setup.sh deliberately omits.
#   setup.sh only runs `apt-get update` + installs specific packages, and relies
#   on unattended-upgrades for ongoing SECURITY patches. This brings the whole
#   base image current (incl. -updates), as a deliberate day-0 action.
# =============================================================================
step_upgrade() {
  if [[ "$CHECK" == "1" ]]; then
    would "apt-get update && apt-get dist-upgrade -y"; return
  fi
  log "apt-get update"; apt-get update -q
  log "apt-get dist-upgrade"
  DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -q
  do_run "apt-get autoremove -y -q"
  if [[ -f /var/run/reboot-required ]]; then
    warn "a reboot is required to finish applying updates (likely a new kernel). Run: sudo reboot"
  else
    ok "system fully upgraded; no reboot required"
  fi
}

# =============================================================================
# STEP: docker — Docker CE from Docker's official SIGNED apt repo (not curl|sh),
#   then add TARGET_USER to the docker group so DevPod et al. can use the socket.
# =============================================================================
step_docker() {
  [[ "$INSTALL_DOCKER" == "true" ]] || { ok "docker disabled (INSTALL_DOCKER=false)"; return; }
  require_user

  if command -v docker &>/dev/null; then
    ok "docker installed ($(docker --version 2>/dev/null))"
  else
    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    local id codename arch
    id="$(. /etc/os-release && echo "${ID:-ubuntu}")"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ "$id" == "ubuntu" || "$id" == "debian" ]] || die "Docker repo step supports ubuntu/debian only (ID=$id)."
    [[ -n "$codename" ]] || die "could not determine VERSION_CODENAME from /etc/os-release."
    arch="$(dpkg --print-architecture)"

    apt_install ca-certificates curl
    do_run "install -m 0755 -d /etc/apt/keyrings"
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
      do_run "curl -fsSL https://download.docker.com/linux/$id/gpg -o /etc/apt/keyrings/docker.asc"
      do_run "chmod a+r /etc/apt/keyrings/docker.asc"
    fi
    local repo="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$id $codename stable"
    if [[ "$CHECK" == "1" ]]; then
      would "write /etc/apt/sources.list.d/docker.list: $repo"
    elif [[ ! -f /etc/apt/sources.list.d/docker.list ]] \
         || ! grep -qF "$repo" /etc/apt/sources.list.d/docker.list; then
      printf '%s\n' "$repo" > /etc/apt/sources.list.d/docker.list
      changed "wrote /etc/apt/sources.list.d/docker.list"
    fi
    do_run "apt-get update -q"
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  do_run "systemctl enable --now docker"

  # docker group ≈ root-equivalent on the host — a conscious trade-off so the
  # dev user can talk to the daemon without sudo (DevPod/IDE need this).
  if id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
    ok "'$TARGET_USER' already in docker group"
  else
    do_run "usermod -aG docker '$TARGET_USER'"
    changed "added '$TARGET_USER' to docker group"
    warn "'$TARGET_USER' must log out/in (new SSH session) for docker group access to take effect."
  fi
  warn "note: docker group membership is effectively root on this host. Fine for a single-user dev box."
}

# =============================================================================
# STEP: brew — Homebrew (Linuxbrew). The installer REFUSES to run as root, so we
#   run it as TARGET_USER and wire `brew shellenv` into their login shells.
# =============================================================================
step_brew() {
  [[ "$INSTALL_BREW" == "true" ]] || { ok "homebrew disabled (INSTALL_BREW=false)"; return; }
  require_user
  apt_install build-essential procps curl file git

  local brew_bin=/home/linuxbrew/.linuxbrew/bin/brew
  if [[ -x "$brew_bin" ]]; then
    ok "homebrew installed ($("$brew_bin" --version 2>/dev/null | head -1))"
  elif [[ "$CHECK" == "1" ]]; then
    would "install Homebrew as $TARGET_USER (NONINTERACTIVE)"
  else
    log "installing Homebrew as '$TARGET_USER'"
    local inst; inst="$(sudo -u "$TARGET_USER" mktemp)"
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$inst"
    chown "$TARGET_USER:$TARGET_USER" "$inst"
    sudo -u "$TARGET_USER" -H env NONINTERACTIVE=1 bash "$inst"
    rm -f "$inst"
    changed "installed Homebrew"
  fi

  # Make brew available in the user's interactive + login shells (idempotent).
  local home; home="$(user_home)"
  local line="eval \"\$($brew_bin shellenv)\""
  add_user_line "$line" "$home/.bashrc"  "brew shellenv"
  add_user_line "$line" "$home/.profile" "brew shellenv"
}

# =============================================================================
# STEP: uv — Astral's uv, installed AS TARGET_USER via the standalone installer
#   (into ~/.local/bin). The installer also adds ~/.local/bin to the user's PATH.
# =============================================================================
step_uv() {
  [[ "$INSTALL_UV" == "true" ]] || { ok "uv disabled (INSTALL_UV=false)"; return; }
  require_user
  local home; home="$(user_home)"
  local uv_bin="$home/.local/bin/uv"

  if [[ -x "$uv_bin" ]]; then
    ok "uv installed ($("$uv_bin" --version 2>/dev/null))"
  elif [[ "$CHECK" == "1" ]]; then
    would "install uv as $TARGET_USER (astral standalone installer)"
  else
    log "installing uv as '$TARGET_USER'"
    apt_install curl
    local inst; inst="$(sudo -u "$TARGET_USER" mktemp)"
    curl -LsSf https://astral.sh/uv/install.sh -o "$inst"
    chown "$TARGET_USER:$TARGET_USER" "$inst"
    sudo -u "$TARGET_USER" -H sh "$inst"
    rm -f "$inst"
    changed "installed uv"
  fi
  ok "tip: '$TARGET_USER' can install Python versions with: uv python install 3.12"
}

# =============================================================================
# STEP: python — system Python base (interpreter + venv + pip + headers).
#   uv (above) manages additional/pinned versions per-project; this is the
#   always-present system baseline.
# =============================================================================
step_python() {
  [[ "$INSTALL_PYTHON" == "true" ]] || { ok "python disabled (INSTALL_PYTHON=false)"; return; }
  apt_install python3 python3-venv python3-pip python3-dev python-is-python3 pipx
  [[ "$CHECK" == "1" ]] && { would "verify system python3 >= 3.12"; return; }

  local ver; ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  ok "system Python: $(python3 --version 2>/dev/null)"
  # Want >= 3.12. On Ubuntu 24.04 apt gives 3.12; 22.04 gives 3.10.
  if [[ -n "$ver" ]] && { [[ "${ver%%.*}" -gt 3 ]] || [[ "${ver#*.}" -ge 12 ]]; }; then
    ok "system python3 is >= 3.12"
  else
    warn "system python3 is $ver (< 3.12). This box's release ships an older Python. \
Provision on Ubuntu 24.04 for 3.12, or use uv: 'uv python install 3.12'."
  fi
}

# =============================================================================
# runner (mirrors setup.sh)
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
}
main "$@"
