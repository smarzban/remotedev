# Security model & what gets hardened

The end state allows inbound traffic **only on `tailscale0`** (v4 **and** v6). The
public interface sees no open ports — the box is reachable only over Tailscale.

> The `firewall` step refuses to seal the box unless Tailscale is `Running`
> (override with `ALLOW_PUBLIC_SSH=true`), and refuses if the current session
> isn't sourced from the Tailscale range — so you can't lock yourself out.

## What `setup.sh` sets up

| Layer | Result |
|---|---|
| **Firewall (UFW)** | Default `deny incoming` / `allow outgoing` / `deny routed`. Inbound allowed **only on `tailscale0`** (v4 **and** v6) — the public internet sees no open ports. |
| **Tailscale** | Installed and joined to the tailnet (TUN mode, no exit node / no advertised routes, Tailscale-SSH off). The primary + only access path. |
| **SSH** | Hardened drop-in: custom port (default `2202`), root login off, **key-only** (no passwords), `MaxAuthTries 3`, kbd-interactive off, X11 off, TCP/agent/tunnel forwarding off, `AllowGroups sudo`, keepalive. Port-bind is asserted before the firewall seals. Runs **standalone, not socket-activated** (see anti-lockout). |
| **fail2ban** | `nftables` banaction, `systemd` backend, `sshd` jail on the custom port. (Largely inert in the default Tailscale-only posture — UFW drops public traffic before it reaches sshd; it matters mainly in the `ALLOW_PUBLIC_SSH=true` fallback.) |
| **unattended-upgrades** | Auto security patching: release + `-security` + ESM apps + ESM infra origins. |
| **AppArmor** | Enabled. |
| **Kernel / sysctl** | Hardening drop-in: `kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, `rp_filter`, `tcp_syncookies`, no redirects/source-routing, martian logging. (Does not touch forwarding — Tailscale owns that.) |
| **Logging** | Persistent journald (so fail2ban/audit history survives reboot). |
| **auditd** (opt-in) | `INSTALL_AUDIT=true` adds a low-noise auth/identity audit ruleset. |
| **Accounts** | A single non-root sudo user with your SSH key (and a sudo password); root SSH disabled and root password locked (`LOCK_ROOT_PASSWORD`). |

## Anti-lockout guarantees

The whole point is to seal the box without ever locking yourself out. `setup.sh`:

- **Fails fast in preflight** if no SSH key is available — *before* a single-use
  Tailscale key is consumed.
- **Won't disable password auth** if the target user would have no key.
- **Runs sshd standalone, not socket-activated.** On Ubuntu 24.04 sshd ships
  socket-activated; fighting `ssh.socket` while restarting `ssh.service` can wedge
  into a no-listener lockout. `setup.sh` disables the socket and runs sshd standalone.
- **Asserts sshd is actually listening** on the new port before the firewall seals.
- **Won't seal** unless Tailscale is `Running` (or you opt into `ALLOW_PUBLIC_SSH`),
  and **refuses if your session isn't on the tailnet** (CGNAT `100.64/10` or `fd7a:`).
- **Seals IPv6 too** (`IPV6=yes`) — a public IPv6 sshd would otherwise stay exposed.

## Idempotency & secrets hygiene

- **Re-runnable.** Files are written only when content differs; packages installed
  only when missing.
- **`CHECK=1`** does a full dry run (no mutations) — even on a fresh box.
- **sshd is validated** (`sshd -t`) before any reload — a bad config never takes
  down the running daemon.
- **Secrets aren't committed or exported.** `config.env` is git-ignored; values are
  sourced without `set -a` so they're never exported into child processes; the
  Tailscale auth key is passed via a `0600` tmpfs file (shredded after), never on
  the process command line.

## Notes vs. the reference posture

- On the reference box the SSH directives lived in the main `sshd_config`; here
  they're in a clean `/etc/ssh/sshd_config.d/99-remotedev-hardening.conf` drop-in
  (same effect, easier to manage).
- Dev tooling (Docker, Node, Python, etc.) is intentionally **out of scope** for
  `setup.sh` — that lives in [`tooling.sh`](tooling.md).
