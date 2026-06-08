# Cleanup (`cleanup.sh`)

Run **last**, once the box is hardened, verified, and tooled. It scrubs every
artifact this toolkit copied onto the box so nothing sensitive or unnecessary
lingers — then removes itself.

```bash
CHECK=1 ./cleanup.sh     # preview what would be removed
./cleanup.sh             # scrub
```

| Removes | |
|---|---|
| `config.env` | **shredded** (held `SUDO_PASSWORD` + the Tailscale auth key) |
| `*.log` | `setup.sh` / `tooling.sh` run logs |
| `setup.sh` `verify.sh` `tooling.sh` | the scripts |
| `cleanup.sh` | itself, last |

It only touches its own directory and only those known files (an allow-list — never
arbitrary files), and is idempotent. The **hardened box itself is untouched** (users,
firewall, sshd, Tailscale, tools all remain) — you'd just re-copy the scripts if you
ever need to re-run them. No root needed if the files are owned by the run user.

> **Why a separate script, not auto-cleanup:** `config.env` is the scripts' *input*,
> and the flow relies on re-running them (idempotent reconcile; phased
> bootstrap → seal → tooling across a reboot). Auto-deleting it at the end of every
> run would break the next phase — so cleanup is an explicit, final step.
