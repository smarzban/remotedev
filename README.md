# remotedev

Take a fresh Ubuntu/Debian VPS to a **hardened, Tailscale-sealed** state — then
optionally make it a dev box. Provider-agnostic, idempotent, and runnable by a
human or an agent over SSH.

The end state accepts inbound traffic **only over Tailscale**; the public internet
sees no open ports. Every script prints the single next command when it finishes,
so you copy-paste your way through the flow.

## Quickstart

```bash
# 1. Configure — copy the template, fill in your keys + secrets (git-ignored)
cp config.env.example config.env && $EDITOR config.env

# 2. Create the box — Hetzner helper (or bring your own VPS and skip to step 3)
COPY_TOOLKIT=true ./provision-hetzner.sh

# 3. Harden it — run bootstrap, then just follow the "Next:" line each script prints
#    (bootstrap → seal over Tailscale → verify → tooling → cleanup)
ssh root@<public-ip> './setup.sh bootstrap'
```

Put `CHECK=1` in front of any script for a full dry-run (changes nothing).

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

Full guide and "who starts where" index: [`docs/`](docs/README.md).

- [Security model & what gets hardened](docs/security-model.md)
- [Configuration reference (`config.env`)](docs/configuration.md)
- [Provisioning a Hetzner box](docs/provisioning.md)
- [Running remotely / go-live flow](docs/running-remotely.md)
- [Dev tooling layer](docs/tooling.md)
- [Cleanup](docs/cleanup.md)
- [Troubleshooting & recovery](docs/troubleshooting.md)

Working on the toolkit itself? See [`CLAUDE.md`](CLAUDE.md) for conventions and the
anti-lockout invariants.
