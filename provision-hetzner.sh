#!/usr/bin/env bash
# =============================================================================
# provision-hetzner.sh — create a Hetzner Cloud VPS, ready to be hardened.
#
# PROVIDER-SPECIFIC (Hetzner / hcloud). It does ONE job: create the box
# (idempotently) and wait until SSH is reachable. Hardening, sealing, tooling
# and cleanup are the provider-AGNOSTIC scripts you run next (setup.sh etc.) —
# kept separate so the core stays portable to other providers.
#
# Config comes from config.env (HCLOUD_* keys) or env vars; sensible defaults
# below. Requires the `hcloud` CLI, already authenticated to a context.
#
#   cp config.env.example config.env && edit            # set HCLOUD_SSH_KEY etc.
#   ./provision-hetzner.sh                               # create the box
#   CHECK=1 ./provision-hetzner.sh                       # dry-run: show, create nothing
#   HCLOUD_SERVER_TYPE=cax21 ./provision-hetzner.sh      # override any setting via env
#   COPY_TOOLKIT=true ./provision-hetzner.sh             # also scp the scripts + config over
#
# After it prints "ready", follow the go-live flow in CLAUDE.md (bootstrap over
# the public IP, then seal the firewall over Tailscale).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
CHECK="${CHECK:-0}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# --- settings (config.env / env vars override these) -----------------------
HCLOUD_SERVER_NAME="${HCLOUD_SERVER_NAME:-remotedev}"
HCLOUD_SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cx23}"      # ARM cax* if available; else cx*/cpx*
HCLOUD_LOCATION="${HCLOUD_LOCATION:-hel1}"
HCLOUD_IMAGE="${HCLOUD_IMAGE:-ubuntu-24.04}"          # 24.04 => Python 3.12 baseline
HCLOUD_SSH_KEY="${HCLOUD_SSH_KEY:-}"                  # name of a key already in your hcloud account
COPY_TOOLKIT="${COPY_TOOLKIT:-false}"                 # also scp the toolkit + config.env to the box
# Hetzner Cloud Firewall (provider-level, in front of the box): during bootstrap
# only HCLOUD_FW_SOURCE may reach SSH. "auto" = this machine's public IPv4.
HCLOUD_FIREWALL="${HCLOUD_FIREWALL:-true}"
HCLOUD_FW_SOURCE="${HCLOUD_FW_SOURCE:-auto}"
# Used only to print the next-step hint (from config.env if present):
TARGET_USER="${TARGET_USER:-deploy}"
SSH_PORT="${SSH_PORT:-2202}"

# --- output helpers (same vocabulary as setup.sh) --------------------------
if [[ -t 1 ]]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_G=; C_Y=; C_R=; C_B=; C_0=; fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
changed() { printf '%s   ~%s %s\n' "$C_Y" "$C_0" "$*"; }
would() { printf '%s   ?%s would: %s\n' "$C_Y" "$C_0" "$*"; }
do_run() { if [[ "$CHECK" == "1" ]]; then would "$*"; else eval "$*"; fi; }

# --- preflight -------------------------------------------------------------
command -v hcloud >/dev/null || die "hcloud CLI not found. Install it: https://github.com/hetznercloud/cli"
hcloud server list >/dev/null 2>&1 || die "hcloud is not authenticated. Run 'hcloud context create <name>' (needs an API token)."
[[ -n "$HCLOUD_SSH_KEY" ]] || die "HCLOUD_SSH_KEY is empty. Set it to an SSH key name in your hcloud account (see 'hcloud ssh-key list')."
hcloud ssh-key describe "$HCLOUD_SSH_KEY" >/dev/null 2>&1 \
  || die "SSH key '$HCLOUD_SSH_KEY' not found in hcloud. Available: $(hcloud ssh-key list -o noheader -o columns=name 2>/dev/null | paste -sd, -)"

log "Hetzner provision plan:"
printf '    name=%s  type=%s  image=%s  location=%s  ssh-key=%s\n' \
  "$HCLOUD_SERVER_NAME" "$HCLOUD_SERVER_TYPE" "$HCLOUD_IMAGE" "$HCLOUD_LOCATION" "$HCLOUD_SSH_KEY"

# --- provider firewall (idempotent) ----------------------------------------
# Closes the bootstrap window: until the UFW seal, sshd is key-only but public.
# This firewall lets ONLY the operator's IP reach :22/:SSH_PORT. Tailscale needs
# no inbound rule (it dials out; the firewall is stateful).
FW_NAME="${HCLOUD_SERVER_NAME}-fw"
FW_ARGS=""
if [[ "$HCLOUD_FIREWALL" == "true" ]]; then
  src="$HCLOUD_FW_SOURCE"
  if [[ "$src" == "auto" ]]; then
    if src="$(curl -fsS -4 --max-time 10 https://api.ipify.org 2>/dev/null)" && [[ -n "$src" ]]; then
      src="$src/32"
    elif [[ "$CHECK" == "1" ]]; then
      warn "could not detect your public IPv4 (dry run continues)."; src="<your-ip>/32"
    else
      die "could not detect your public IPv4 for the firewall. Set HCLOUD_FW_SOURCE=<ip>/32 (or HCLOUD_FIREWALL=false)."
    fi
  fi
  [[ "$src" == */* ]] || src="$src/32"
  rules_json="$(printf '[{"direction":"in","protocol":"tcp","port":"22","source_ips":["%s"],"description":"bootstrap ssh"},{"direction":"in","protocol":"tcp","port":"%s","source_ips":["%s"],"description":"bootstrap ssh (hardened port)"}]' \
    "$src" "$SSH_PORT" "$src")"
  if [[ "$CHECK" == "1" ]]; then
    would "create-or-update firewall '$FW_NAME': SSH (22, $SSH_PORT) from $src only"
  else
    rules="$(mktemp)"; trap 'rm -f "$rules"' EXIT
    printf '%s\n' "$rules_json" > "$rules"
    if hcloud firewall describe "$FW_NAME" >/dev/null 2>&1; then
      # Re-sync every run: your IP or SSH_PORT may have changed since it was made.
      hcloud firewall replace-rules "$FW_NAME" --rules-file "$rules" >/dev/null
      ok "firewall '$FW_NAME' rules synced (SSH from $src only)"
    else
      hcloud firewall create --name "$FW_NAME" --rules-file "$rules" --label project=remotedev >/dev/null
      changed "created firewall '$FW_NAME' (SSH from $src only)"
    fi
  fi
  FW_ARGS="--firewall '$FW_NAME'"
fi

# --- create (idempotent) ---------------------------------------------------
CREATED=0
if hcloud server describe "$HCLOUD_SERVER_NAME" >/dev/null 2>&1; then
  ok "server '$HCLOUD_SERVER_NAME' already exists — not recreating."
else
  do_run "hcloud server create --name '$HCLOUD_SERVER_NAME' --type '$HCLOUD_SERVER_TYPE' \
--image '$HCLOUD_IMAGE' --location '$HCLOUD_LOCATION' --ssh-key '$HCLOUD_SSH_KEY' --label project=remotedev $FW_ARGS"
  CREATED=1
  [[ "$CHECK" == "1" ]] || changed "created server '$HCLOUD_SERVER_NAME'"
fi

if [[ "$CHECK" == "1" ]]; then
  would "wait for SSH on :22, then print next steps"
  log "dry-run complete — nothing created."
  exit 0
fi

# --- discover IP + wait for SSH --------------------------------------------
IP="$(hcloud server ip "$HCLOUD_SERVER_NAME" 2>/dev/null)" || true
[[ -n "$IP" ]] || die "could not determine public IPv4 for '$HCLOUD_SERVER_NAME'."
log "public IPv4: $IP — waiting for SSH (:22) to come up..."
ready=0
for _ in $(seq 1 30); do
  if nc -z -G 5 "$IP" 22 2>/dev/null || nc -z -w 5 "$IP" 22 2>/dev/null; then ready=1; break; fi
  sleep 5
done
[[ "$ready" == "1" ]] || die "SSH on $IP:22 did not come up in time. Check the Hetzner console."
ok "SSH is up on $IP:22"

# --- clear stale host key on a freshly-created box -------------------------
# Hetzner recycles public IPs: a deleted box's key may still be pinned in
# known_hosts for this IP, which makes scp/ssh fail strict-checking with
# "REMOTE HOST IDENTIFICATION HAS CHANGED". We only created the box just now,
# so any pinned key for this IP is definitionally stale — drop it (accept-new
# below re-pins the real one). Guarded on CREATED so we never touch the pin of
# a pre-existing box we didn't make.
if [[ "$CREATED" == "1" ]] && command -v ssh-keygen >/dev/null; then
  if ssh-keygen -F "$IP" >/dev/null 2>&1; then
    do_run "ssh-keygen -R '$IP' >/dev/null 2>&1 || true"
    changed "removed stale known_hosts entry for $IP (recycled IP)"
  fi
fi

# --- optional: copy the toolkit over ---------------------------------------
if [[ "$COPY_TOOLKIT" == "true" ]]; then
  log "copying toolkit + config.env to root@$IP:~ (chmod 600 config.env)"
  scp -o StrictHostKeyChecking=accept-new \
    "$SCRIPT_DIR"/setup.sh "$SCRIPT_DIR"/verify.sh "$SCRIPT_DIR"/tooling.sh \
    "$SCRIPT_DIR"/cleanup.sh "$SCRIPT_DIR"/config.env "root@$IP:~/"
  ssh -o StrictHostKeyChecking=accept-new "root@$IP" 'chmod 600 ~/config.env; chmod +x ~/*.sh'
  changed "toolkit copied to root@$IP"
fi

# --- next step -------------------------------------------------------------
# Print ONLY the immediate next command; each script then prints the one after
# it (bootstrap → seal → verify → tooling → cleanup), so the operator just
# follows along instead of reading a wall of runbook up front.
log "Box '$HCLOUD_SERVER_NAME' is ready at $IP."
echo
if [[ "$COPY_TOOLKIT" != "true" ]]; then
  log "Next — copy the toolkit over, then bootstrap (it prints the step after it):"
  echo "    scp setup.sh verify.sh tooling.sh cleanup.sh config.env root@$IP:~/ && ssh root@$IP 'chmod 600 ~/config.env && chmod +x ~/*.sh'"
  echo "    ssh root@$IP './setup.sh bootstrap'"
else
  log "Next — bootstrap over the public IP (everything EXCEPT the firewall seal):"
  echo "    ssh root@$IP './setup.sh bootstrap'"
fi
echo
echo "(Each script prints the next command when it finishes — just follow along: seal → verify → tooling → cleanup.)"
if [[ "$HCLOUD_FIREWALL" == "true" ]]; then
  echo
  echo "After the seal, drop the bootstrap SSH rules so the provider firewall is deny-all too:"
  echo "    hcloud firewall replace-rules '$FW_NAME' --rules-file <(echo '[]')"
fi
