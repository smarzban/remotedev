# CLAUDE.md — remotedev

Instructions and durable context for anyone (human or agent) working on this repo.
Auto-loaded by Claude Code from the repo regardless of which folder/machine it lives in,
so this file — **not** any machine-local memory — is the portable source of truth.

> **No identifiers in this file.** It is committed and may be shared. Keep box-specific
> operational state (IPs, tailnet names, hostnames, secrets) out of here — those live in
> the git-ignored `NOTES.local.md` (see bottom).

## What this repo is

A provider-agnostic toolkit to take a fresh Ubuntu/Debian VPS to a **hardened, Tailscale-sealed**
state, then optionally make it a dev host. Reproducible by a human or an agent over SSH.

| Script | Role |
|---|---|
| `provision-hetzner.sh` | **Provider-specific** (Hetzner/hcloud). Creates the box only (idempotent), waits for SSH, prints next steps. Does not harden. |
| `setup.sh` | Security/access hardening core. Steps: `preflight user tailscale ssh fail2ban autoupgrades apparmor sysctl journald audit firewall` |
| `verify.sh` | Read-only posture audit (exits nonzero on any fail) |
| `tooling.sh` | Optional dev layer: `upgrade docker brew uv python` |
| `cleanup.sh` | Final scrub of provisioning artifacts (shreds `config.env`, removes logs + scripts + self) |
| `config.env` | Per-box input (secrets). **git-ignored**, never committed |

## Security model (the point of the whole thing)

The end state allows inbound **only on `tailscale0`** (v4 **and** v6); the public interface sees
no open ports. Reachable only over Tailscale.

## Conventions — follow these

- **Bash, idempotent, re-runnable.** Write files only when content differs; install packages only when missing.
- **`CHECK=1` must stay a true full dry-run** — every mutating path guarded so a dry run changes nothing and exits 0 (even on a fresh box where the target user doesn't exist yet).
- **Lint before commit:** `bash -n` and `shellcheck -S warning` must be clean.
- **Match the existing style:** the `log/ok/warn/die/changed/would`, `do_run`, `write_file`, `apt_install` helpers; per-step functions `step_<name>`; sourced config without `set -a` (no secret export to children).
- **Security core stays minimal & bootstrap-safe.** Heavy/dev things (full `dist-upgrade`, Docker, language runtimes) go in `tooling.sh`, never `setup.sh`.
- **Secrets never committed.** `config.env` is git-ignored; auth keys passed via a 0600 tmpfs file, never argv.
- End the lifecycle with `cleanup.sh` so nothing sensitive lingers on the box.

## Anti-lockout invariants — do not break these

1. **sshd runs standalone, NOT socket-activated.** On Ubuntu 24.04 sshd ships socket-activated; overriding `ssh.socket` while also restarting `ssh.service` fights over the port and can wedge into a **no-listener lockout**. `setup.sh` disables `ssh.socket` and runs sshd standalone honoring `Port`. Keep it that way.
2. **`firewall` runs last and self-gates.** It refuses to seal unless Tailscale is `Running` (override: `ALLOW_PUBLIC_SSH=true`) and warns/aborts if the current session isn't sourced from the Tailscale range (CGNAT `100.64/10` or `fd7a:`).
3. **The seal must be run from a Tailscale session.** Bootstrap over the public IP up to the tailnet join, then reconnect over Tailscale to run `firewall`.
4. **Never disable password auth if the target user has no key.** Preflight fails fast if no key is available.
5. **Seal IPv6 too** (`IPV6=yes` in `/etc/default/ufw`) — a public IPv6 sshd would otherwise stay exposed.

## Lessons already learned (don't re-introduce)

- **`verify.sh` has no `pipefail`** on purpose: `cmd | grep -q` makes the producer catch SIGPIPE (exit 141); with `pipefail` that became a flaky false FAIL. `grep`'s own exit status is the truth.
- **`fs.protected_regular=2`** (set by `step_sysctl`) blocks root from writing a user-owned file in sticky `/tmp`. So installers run **as the target user** via the upstream pipe form (no cross-owned temp file), and Homebrew's prefix `/home/linuxbrew` is pre-created owned by the user so its non-interactive installer needn't password-sudo.
- **`tooling.sh` reboot gate:** if `upgrade` pulls a new kernel and later steps remain, it stops → reboot → re-run continues (idempotent). Keeps the dist-upgrade/reboot dance out of `setup.sh`.

## Go-live flow (proven)

1. Provider create — `./provision-hetzner.sh` (Hetzner), or `hcloud server create … --image ubuntu-24.04` / any provider, with your SSH key for initial root.
2. `scp` scripts + `config.env` to `~`; `ssh root@public` → `setup.sh` for everything **except** `firewall` (joins tailnet).
3. From a machine on the same tailnet: `ssh <user>@<tailscale-ip> -p <port>` → `sudo setup.sh firewall` → `verify.sh`.
4. `tooling.sh` (reboot gate may fire) → reboot → `tooling.sh` again for the tools.
5. `cleanup.sh`.

## Roadmap / open items

- `provision-hetzner.sh` is create-only by design. A future fuller orchestrator (create → setup → seal → tooling → cleanup in one command) could build on it if wanted.
- DevPod: host runs the container natively; `ALLOW_SSH_FORWARDING=false` may block IDE port-forwarding — flip if needed.
- Ubuntu **24.04** is the target (Python 3.12 baseline; 22.04 ships 3.10).

---

### Operational state lives outside this file

Per-box facts (which boxes exist, their IPs, tailnet names) are **not** here — they're identifiers.
See `NOTES.local.md` (git-ignored) on this machine for that. When picking up work on a specific box,
read that file first.
