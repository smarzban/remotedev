# remotedev-bootstrap

Reproduce a hardened, sealed security posture on any fresh Ubuntu/Debian VPS,
on any provider. Provider-agnostic, idempotent, and runnable by either a human
or an automated agent over SSH.

## What it sets up

| Layer | Result |
|---|---|
| **Firewall (UFW)** | Default `deny incoming` / `allow outgoing` / `deny routed`. Inbound allowed **only on `tailscale0`** (v4 **and** v6) — the public internet sees no open ports. |
| **Tailscale** | Installed and joined to the tailnet (TUN mode, no exit node / no advertised routes, Tailscale-SSH off). The primary + only access path. |
| **SSH** | Hardened drop-in: custom port (default `2202`), root login off, **key-only** (no passwords), `MaxAuthTries 3`, kbd-interactive off, X11 off, TCP/agent/tunnel forwarding off, `AllowGroups sudo`, keepalive. Port-bind is asserted before the firewall seals (handles socket-activated sshd). |
| **fail2ban** | `nftables` banaction, `systemd` backend, `sshd` jail on the custom port. (Largely inert in the default Tailscale-only posture — UFW drops public traffic before it reaches sshd; it matters mainly in the `ALLOW_PUBLIC_SSH=true` fallback.) |
| **unattended-upgrades** | Auto security patching: release + `-security` + ESM apps + ESM infra origins. |
| **AppArmor** | Enabled. |
| **Kernel / sysctl** | Hardening drop-in: `kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, `rp_filter`, `tcp_syncookies`, no redirects/source-routing, martian logging. (Does not touch forwarding — Tailscale owns that.) |
| **Logging** | Persistent journald (so fail2ban/audit history survives reboot). |
| **auditd** (opt-in) | `INSTALL_AUDIT=true` adds a low-noise auth/identity audit ruleset. |
| **Accounts** | A single non-root sudo user with your SSH key (and a sudo password); root SSH disabled and root password locked (`LOCK_ROOT_PASSWORD`). |

> **Security model:** the hardened end-state is reachable **only over Tailscale**.
> The `firewall` step refuses to seal the box unless Tailscale is `Running`
> (override with `ALLOW_PUBLIC_SSH=true`).

## Usage

```bash
git clone <this-repo> && cd remotedev-bootstrap
cp config.env.example config.env
$EDITOR config.env        # SSH_AUTHORIZED_KEYS, TS_AUTHKEY, SUDO_PASSWORD (+ SSH_PORT/TARGET_USER)

# Dry run first — prints every change, makes none:
sudo CHECK=1 ./setup.sh

# Apply:
sudo ./setup.sh

# Verify the posture afterwards (read-only; needs root for full detail):
sudo ./verify.sh
```

**`config.env` is the canonical input path** — it survives `sudo`'s `env_reset`.
If you'd rather pass secrets as environment variables, you **must** use `sudo -E`
(otherwise `sudo` strips `SUDO_PASSWORD`/`TS_AUTHKEY` and the run aborts):

```bash
SUDO_PASSWORD='…' TS_AUTHKEY='…' sudo -E ./setup.sh
```

Run individual steps by name:

```bash
sudo ./setup.sh ssh firewall
# steps: preflight user tailscale ssh fail2ban autoupgrades apparmor sysctl journald audit firewall
```

### Running it remotely (agent / one-shot)

`config.env` holds a Tailscale auth key — **do not** leave it in world-readable
`/tmp`. Copy to the deploy user's home, lock it down, and remove it after:

```bash
scp setup.sh verify.sh config.env user@newbox:~/        # ~ , not /tmp
ssh user@newbox 'chmod 600 ~/config.env && sudo ./setup.sh && shred -u ~/config.env'
```

> **Bootstrap window:** the `firewall` step runs *last* (anti-lockout), so between
> the `ssh` and `firewall` steps a hardened-but-public sshd is briefly reachable on
> `SSH_PORT`. Keep a provider security group / cloud firewall in front of the box
> during bootstrap; re-running converges and the firewall step removes stray public
> rules. Use an **ephemeral, single-use** Tailscale auth key.

## Config (`config.env`)

| Key | Meaning |
|---|---|
| `TARGET_USER` | Non-root sudo user to create/harden (default `deploy`). |
| `SUDO_PASSWORD` | Password for `TARGET_USER` (sudo requires one; SSH stays key-only). If empty, the script prompts interactively. Set as an env var for one-shot runs. |
| `SSH_AUTHORIZED_KEYS` | Public key(s) to authorize. If empty, existing keys are kept; SSH won't be locked down if the user would have no key. |
| `SSH_PORT` | SSH port (default `2202`; choose your own). |
| `TS_AUTHKEY` | Tailscale auth key — generate at <https://login.tailscale.com/admin/settings/keys>. Use an **ephemeral, single-use, tagged** key. Passed via a 0600 tmpfs file, never on the command line. Required unless `ALLOW_PUBLIC_SSH=true`. |
| `TS_HOSTNAME` | Tailscale machine name (defaults to system hostname). |
| `ALLOW_PUBLIC_SSH` | `false` (default) = public interface fully sealed. `true` = also open `SSH_PORT` publicly. |
| `ALLOW_SSH_FORWARDING` | `false` (default) = TCP/agent/tunnel forwarding disabled. `true` to allow. |
| `LOCK_ROOT_PASSWORD` | `true` (default) = lock the root password (only after the user has a key). `false` if your provider console needs root login. |
| `INSTALL_AUDIT` | `false` (default). `true` installs `auditd` with an auth/identity ruleset. |

## Safety / idempotency notes

- **Re-runnable.** Files are written only when content differs; packages installed only when missing.
- **`CHECK=1`** does a full dry run (no mutations).
- **sshd is validated** (`sshd -t`) before any reload — a bad config never takes down the running daemon.
- **Anti-lockout guards:** fails fast in preflight if no SSH key is available (before a single-use Tailscale key is consumed); won't disable password auth if the target user has no key; asserts sshd is actually listening on the new port before the firewall seals; won't seal the firewall unless Tailscale is `Running` (or you opt into public SSH); detects the session source (Tailscale CGNAT `100.64/10` or `fd7a:` v6) and refuses to seal if you're on a non-Tailscale link.
- **Secrets hygiene:** `config.env` is git-ignored; secrets are not exported into child processes; the Tailscale auth key is passed via a 0600 tmpfs file (shredded after), never via the process command line.

## Dev tooling (`tooling.sh`)

`setup.sh` is security/access only. **`tooling.sh`** is a separate, optional
layer that makes a hardened box useful for development — run it **after**
`setup.sh` (it needs `TARGET_USER` to exist). It shares the same `config.env`,
`CHECK=1` dry-run, and per-step conventions.

```bash
sudo CHECK=1 ./tooling.sh        # dry run
sudo ./tooling.sh                # everything (respecting toggles)
sudo ./tooling.sh docker uv      # only named steps
# steps: upgrade docker brew uv python
```

| Step | Result |
|---|---|
| **upgrade** | Full `apt-get dist-upgrade` — the one thing `setup.sh` deliberately omits (it only does `update` + relies on unattended-upgrades for *security* patches). Warns if a reboot is required. |
| **docker** | Docker CE from Docker's **signed apt repo** (not `curl\|sh`), service enabled, and `TARGET_USER` added to the `docker` group (so DevPod/IDEs can use the socket without sudo). |
| **brew** | Homebrew (Linuxbrew), installed **as `TARGET_USER`** (the installer refuses root) and wired into their login shells. |
| **uv** | Astral `uv`, installed **as `TARGET_USER`** into `~/.local/bin`. Use `uv python install <ver>` for pinned/extra Python versions. |
| **python** | System Python base: `python3` + `venv` + `pip` + `dev` headers + `pipx` + `python-is-python3`. |

Toggles (in `config.env`): `INSTALL_DOCKER`, `INSTALL_BREW`, `INSTALL_UV`,
`INSTALL_PYTHON` (all default `true`; the `upgrade` step always runs).

> **Security note:** adding `TARGET_USER` to the `docker` group is effectively
> root-equivalent on the host — an accepted trade-off for a single-user dev box.
> Skip it with `INSTALL_DOCKER=false` if you don't need a local container runtime
> (e.g. you run DevPod against a Kubernetes provider instead).

> **Reboot ordering:** if the `upgrade` step pulls a new kernel it'll ask for a
> reboot. On a Tailscale-sealed box, reconnect over the tailnet afterwards.

## Notes vs. the reference posture

- On the reference box the SSH directives lived in the main `sshd_config`; here they're in a
  clean `/etc/ssh/sshd_config.d/99-remotedev-hardening.conf` drop-in (same effect, easier to manage).
- Dev tooling (Docker, Node, Python, etc.) is intentionally **out of scope** for now —
  this repo is security/access only.
