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
| `tooling.sh` | Optional dev layer: `upgrade docker brew uv python node` |
| `cleanup.sh` | Final scrub of provisioning artifacts (shreds `config.env`, removes logs + scripts + self) |
| `ssh-alias.sh` | **Local, optional.** Writes a `Host <name>` block to the operator's `~/.ssh/config` (Tailscale IP via local `tailscale ip -4`). Runs on the Mac, never on the box. |
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
- **Running steps over SSH (proven on a 2nd box):** `sudo` over `ssh` needs a TTY — use `ssh -t` or you get *"sudo: a terminal is required"*. Scripts copied as root sit in `/root`, so when you seal/verify/tool as the sudo user, call them by absolute path (`sudo bash /root/<script>`). And keep the remote command on **one line** — a newline inside the quotes turns `&& sudo bash /root/verify.sh` into a bare `sudo bash` (an interactive root shell) and the rest never runs.
- **Self-guiding next-step output:** each script prints the *single* next command on success (provision → `setup.sh bootstrap` → seal → `verify.sh` → `tooling.sh` → `cleanup.sh`), pre-filled with the box's Tailscale IP where it knows it. `setup.sh bootstrap` is an alias = all steps except `firewall`. Keep these emitters out of the exit-status path (they run after `log done`, guarded by `CHECK`). Don't reintroduce a single up-front wall-of-runbook dump.
- **Recycled-IP host keys:** Hetzner reuses public IPs, so a deleted box's key lingers pinned in local `known_hosts` and trips "REMOTE HOST IDENTIFICATION HAS CHANGED" on the next box. `provision-hetzner.sh` clears the stale entry **only when it just created the box** (`CREATED=1`), never for a pre-existing one. Manual fix for the already-exists case: `ssh-keygen -R <ip>`.
- **Docker bypasses UFW** (its iptables rules sit ahead of UFW's), so a published port would break the seal. `tooling.sh` pins `daemon.json` `"ip": "127.0.0.1"`; `verify.sh` fails on wildcard-published container ports. Don't remove either.
- **Tailscale key must be tagged and NOT ephemeral.** Ephemeral nodes are deleted when offline and untagged node keys expire (~180d) — both are delayed lockouts of a sealed box. `setup.sh` warns, `verify.sh` fails on key expiry.
- **The SSH alias is a standalone LOCAL script (`ssh-alias.sh`), run on the operator's machine — never on the box.** An `~/.ssh/config` alias is a local artifact; `setup.sh`/`cleanup.sh` run *on the box* and can't touch the operator's machine. `ssh-alias.sh` resolves the box's Tailscale IP locally via `tailscale ip -4 <name>` (the Mac's own tailnet view — no SSH into the box, no MagicDNS dependency) and writes a marker-delimited managed block (idempotent). It's optional/opt-in (just run it), so there's deliberately **no config flag**; `cleanup.sh` prints a one-line reminder to run it. It is NOT scp'd to the box and NOT in `cleanup.sh`'s remove-list.

## Go-live flow (proven)

Each script prints the next command, so in practice you follow the chain. The full sequence:

1. Provider create — `./provision-hetzner.sh` (Hetzner), or `hcloud server create … --image ubuntu-24.04` / any provider, with your SSH key for initial root.
2. `scp` scripts + `config.env` to `~`; `ssh root@public './setup.sh bootstrap'` — everything **except** `firewall` (joins tailnet).
3. From a machine on the same tailnet, seal then verify — note `ssh -t` (TTY for sudo's password) and **absolute** script paths (they were copied as root into `/root`, but you're the sudo user now), each on **one line**:
   `ssh -t <user>@<tailscale-ip> -p <port> 'sudo bash /root/setup.sh firewall'` then `… 'sudo bash /root/verify.sh'`
4. `tooling.sh` (reboot gate may fire) → reboot → `tooling.sh` again for the tools.
5. `cleanup.sh`.

(Full operator-facing detail lives in `README.md` + `docs/`; this is the maintainer summary.)

## Roadmap / open items

- `provision-hetzner.sh` is create-only by design. A future fuller orchestrator (create → setup → seal → tooling → cleanup in one command) could build on it if wanted.
- DevPod: host runs the container natively; `ALLOW_SSH_FORWARDING=false` may block IDE port-forwarding — flip if needed.
- Ubuntu **24.04** is the target (Python 3.12 baseline; 22.04 ships 3.10).

---

### Operational state lives outside this file

Per-box facts (which boxes exist, their IPs, tailnet names) are **not** here — they're identifiers.
See `NOTES.local.md` (git-ignored) on this machine for that. When picking up work on a specific box,
read that file first.
