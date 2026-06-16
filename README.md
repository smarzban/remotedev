# remotedev

**Take a fresh Ubuntu/Debian VPS to a hardened, Tailscale-sealed state — then,
optionally, make it a dev box.** A provider-agnostic, idempotent Bash toolkit that
firewalls the box down to **Tailscale-only ingress** (key-only SSH, fail2ban,
automatic security updates, kernel/sysctl hardening) and is safe to drive over SSH
by a human or an agent.

The end state accepts inbound traffic **only over Tailscale** — the public internet
sees no open ports. Every script prints the single next command when it finishes, so
you copy-paste your way through the flow.

## Highlights

- **Tailscale-only ingress.** UFW default-deny with inbound allowed *only* on
  `tailscale0` (IPv4 **and** IPv6). The public interface has no open ports.
- **Anti-lockout by design.** The seal refuses to run unless Tailscale is up and your
  session is on the tailnet, sshd is asserted listening on the new port *before* the
  firewall closes, and password auth is never disabled while the user has no key.
- **Idempotent + dry-run.** Re-run any step any time; prefix any script with `CHECK=1`
  to preview every change without touching the box.
- **Self-guiding.** Each script prints the one command to run next, walking you
  through provision → harden → seal → verify → tooling → cleanup.
- **Secrets hygiene.** `config.env` is git-ignored and never exported to child
  processes; the Tailscale auth key is passed via a `0600` tmpfs file (never on the
  command line); `cleanup.sh` shreds it at the end.
- **Optional dev layer.** `tooling.sh` adds Docker, Homebrew, uv, Python, and Node —
  kept deliberately out of the security core.

## Requirements

- A target VPS running **Ubuntu 24.04** (22.04 also works; 24.04 gives a Python 3.12
  baseline). Other distros are out of scope.
- A **Tailscale** account and an auth key — use an **ephemeral, single-use, tagged**
  key ([generate one](https://login.tailscale.com/admin/settings/keys)).
- An **SSH keypair** — the public key is authorized on the box; password SSH is
  disabled.
- *For the Hetzner helper only:* the authenticated [`hcloud` CLI](https://github.com/hetznercloud/cli).
  Other providers: create the box yourself with your SSH key for root, then start at
  `setup.sh`.

## Quickstart

Works on **any** Ubuntu/Debian VPS you can SSH into as root — bring your own box:

```bash
# 1. Configure (git-ignored) — your SSH public key, a sudo password, a Tailscale auth key
cp config.env.example config.env && $EDITOR config.env

# 2. Copy the toolkit onto a fresh Ubuntu box you can reach as root (any provider)
scp setup.sh verify.sh tooling.sh cleanup.sh config.env root@<host>:~/
ssh root@<host> 'chmod 600 ~/config.env && chmod +x ~/*.sh'

# 3. Harden + join the tailnet, then follow the "Next:" line each script prints
#    (bootstrap → seal over Tailscale → verify → tooling → cleanup)
ssh root@<host> './setup.sh bootstrap'
```

On Hetzner? `COPY_TOOLKIT=true ./provision-hetzner.sh` creates the box **and** copies
the toolkit for you in one step — see [provisioning](docs/provisioning.md). Prefix
any script with `CHECK=1` for a full dry-run (changes nothing).

**New here? Follow the [full guide](docs/guide.md)** — the complete end-to-end
walkthrough from a fresh box to sealed, verified, and tooled.

## The scripts

| Script | Role |
|---|---|
| `provision-hetzner.sh` | **Hetzner-only.** Create the VPS, wait for SSH. Hand off to `setup.sh`. |
| `setup.sh` | Security hardening + Tailscale seal. The core. |
| `verify.sh` | Read-only posture audit (exits non-zero on any fail). |
| `tooling.sh` | Optional dev layer: Docker, Homebrew, uv, Python, Node. |
| `cleanup.sh` | Shred secrets + remove the toolkit from the box. |
| `ssh-alias.sh` | **Local, optional.** Add an `~/.ssh/config` alias so you can `ssh <name>` over Tailscale. |

## Docs

Start with the **[full guide](docs/guide.md)** for the end-to-end walkthrough, or
the [docs index](docs/README.md) for the "who starts where" map.

- [Full guide — fresh box to sealed & tooled](docs/guide.md)
- [Security model & what gets hardened](docs/security-model.md)
- [Configuration reference (`config.env`)](docs/configuration.md)
- [Provisioning a Hetzner box (optional helper)](docs/provisioning.md)
- [Running remotely — SSH mechanics & gotchas](docs/running-remotely.md)
- [Dev tooling layer](docs/tooling.md)
- [Cleanup](docs/cleanup.md)
- [Troubleshooting & recovery](docs/troubleshooting.md)

Working on the toolkit itself? See [`CLAUDE.md`](CLAUDE.md) for conventions and the
anti-lockout invariants.
