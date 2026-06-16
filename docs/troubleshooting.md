# Troubleshooting & recovery

This toolkit is built to **fail safe**: the dangerous steps refuse to run rather
than risk locking you out, every script is idempotent (re-running is safe and
converges), and `CHECK=1` previews any script without changing anything. So when
something stops, the fix is almost always "satisfy the guard and re-run the step".

This page lists the failure modes you'll actually hit, the exact message each one
prints, and what to do. It's organised by symptom.

## First check: are you using the Tailscale IP?

The whole point of the seal is that the **public IP stops answering** — inbound is
allowed only on `tailscale0`. "I can no longer `ssh root@<public-ip>`" after the
`firewall` step is **the toolkit working**, not a lockout. Reconnect over Tailscale:

```bash
tailscale ip -4 <name>                       # the box's tailnet IP (run locally)
ssh -t <user>@<tailscale-ip> -p <port> '…'   # or just: ssh <name>  (see ssh-alias.sh)
```

A real lockout is only when the box is sealed **and** Tailscale is down — see
[Locked out completely](#locked-out-completely) at the bottom.

## The `firewall` (seal) step refuses to run

`firewall` is the lockout-sensitive step, so it guards itself. All three of these
are deliberate — they stop you sealing into a box you can't get back into.

| Message | Cause | Fix |
|---|---|---|
| `Refusing to seal firewall: Tailscale is not Running (state='…')` | The box hasn't joined the tailnet, so sealing would cut the only access path. | Bring Tailscale up first: `sudo ./setup.sh tailscale` (needs `TS_AUTHKEY`). Then re-run `firewall`. Or set `ALLOW_PUBLIC_SSH=true` to keep public SSH open. |
| `You appear to be connected over a NON-Tailscale address (…). … aborting to prevent lockout.` | Your current SSH session came in over the public IP, not the tailnet — sealing would drop it. | Reconnect over the **Tailscale IP** (see above), then run `firewall` from that session. Or `ALLOW_PUBLIC_SSH=true`. |
| `Could not determine this session's source address; relying on the Tailscale-Running gate.` | Only a warning — the script couldn't read your session's source and falls back to the "Tailscale Running" gate. | If you're genuinely on the tailnet, it's fine. If you might be on a public link, reconnect over Tailscale to be safe before sealing. |

> Under `CHECK=1` these become warnings (the dry run continues so you can see the
> whole plan); on a real run they're hard stops.

## The `ssh` step refuses, or sshd won't come up

| Message | Cause | Fix |
|---|---|---|
| `Refusing to harden SSH: '<user>' has no authorized_keys.` | Anti-lockout: disabling password auth with no key on the account would strand you. | Put a key in `SSH_AUTHORIZED_KEYS` (in `config.env`) and re-run the `user` step, then `ssh`. |
| `sshd config test failed — NOT reloading (existing sshd untouched).` | `sshd -t` rejected the generated drop-in; the running daemon was left alone (good). | Run `sshd -t` to see the parse error, fix `config.env` (e.g. a bad `SSH_PORT`), re-run. The drop-in lives at `/etc/ssh/sshd_config.d/99-remotedev-hardening.conf`. |
| `sshd is NOT listening on port <port> after restart — aborting before the firewall seals the box.` | sshd restarted but isn't bound to the expected port — the script refuses to seal a box whose sshd is mis-bound. | `journalctl -u ssh` (the message says so). Usually socket-activation interference — see below. |

> **The `ssh.socket` / no-listener trap (Ubuntu 24.04).** 24.04 ships sshd
> *socket-activated*: `ssh.socket` owns the port and `sshd_config`'s `Port` is
> ignored. Fighting the socket while restarting `ssh.service` can wedge into a
> **no-listener lockout**. `setup.sh` handles this — it disables `ssh.socket` and
> runs sshd standalone honoring `Port`. If you hit this after manual tinkering:
> `systemctl disable --now ssh.socket && systemctl enable --now ssh` then re-run
> `setup.sh ssh`.

## `setup.sh` refuses to even start

```
No SSH key available for '<user>': set SSH_AUTHORIZED_KEYS in config.env …
Override with ALLOW_PUBLIC_SSH=true.
```

Preflight refuses to begin a run it can't finish — specifically so a **single-use
Tailscale auth key isn't burned** on a run that would abort later at the `ssh` step.
Set `SSH_AUTHORIZED_KEYS` in `config.env` (or give `<user>` an `authorized_keys`
file), or set `ALLOW_PUBLIC_SSH=true` if you really want the no-VPN fallback.

```
Tailscale not connected and TS_AUTHKEY is empty …
```

The `tailscale` step needs an auth key to join the tailnet. Set `TS_AUTHKEY` (an
[ephemeral, single-use, tagged key](configuration.md)), or `ALLOW_PUBLIC_SSH=true`
to skip the tailnet join.

```
unknown step '<x>' (valid: preflight user tailscale ssh fail2ban autoupgrades apparmor sysctl journald audit firewall | bootstrap)
```

You passed a step name that doesn't exist. The valid set is listed; `bootstrap` =
every step except `firewall`.

## Can't connect at all

| Symptom | Cause | Fix |
|---|---|---|
| `REMOTE HOST IDENTIFICATION HAS CHANGED` on `ssh`/`scp` | Recycled public IP — your local `known_hosts` has a deleted box's key pinned for this IP. | `ssh-keygen -R <ip>`. `provision-hetzner.sh` does this automatically, but only for boxes **it** just created (see [provisioning](provisioning.md#recycled-ip-host-keys)). |
| `sudo: a terminal is required to read the password` | `sudo` over SSH needs a TTY. | Use `ssh -t …` for any remote command that runs `sudo`. |
| The command opened an interactive root shell and "did nothing" | A newline inside the quoted remote command split it — `… && sudo bash` became a bare `sudo bash` (a root shell). | Keep each remote command on **one line**. |
| `Permission denied (publickey)` connecting as `<user>` | sshd is key-only and limited to `AllowGroups sudo`; your key isn't on the account, or the user isn't in `sudo`. | Confirm your public key is in `SSH_AUTHORIZED_KEYS`; re-run the `user` step. Verify with `verify.sh`. |
| `sudo` rejects your password | The sudo password is set once, during the `user` step (from `SUDO_PASSWORD` or the interactive prompt) and isn't changed on re-runs. | Reset it from a console/recovery session: `passwd <user>`. (SSH stays key-only regardless.) |

## Locked out completely

You're sealed **and** Tailscale won't come up, so neither the public IP nor the
tailnet answers. Recover out-of-band:

1. **Open your provider's web/serial console** (Hetzner: the Console button) or boot
   **rescue/recovery mode**. Note: with `LOCK_ROOT_PASSWORD=true` (the default) the
   serial console **won't accept a root login** — that's the point — so you'll need
   rescue mode (which boots a separate OS and lets you mount the disk) to get in.
2. **Reopen access temporarily** — from the console/rescue shell:
   ```bash
   ufw allow <port>/tcp     # reopen the SSH port publicly, or:
   ufw disable              # drop the firewall entirely (re-seal later)
   systemctl status ssh     # confirm sshd is up and on the right port
   tailscale status         # see why the tailnet join failed
   ```
3. **Get back in over the public IP**, fix the root cause (usually: Tailscale didn't
   start, or sshd bound the wrong port), then **re-run the relevant step** and
   re-seal: `sudo ./setup.sh tailscale ssh firewall`.

> Prevention: keep a provider security group / cloud firewall in front of the box
> during the public-IP bootstrap window, and verify with `verify.sh` *before* you
> disconnect — it exits non-zero if the posture isn't right.

## Dev tooling (`tooling.sh`)

| Message / symptom | Fix |
|---|---|
| `user '<user>' does not exist. Run setup.sh first: 'sudo ./setup.sh user'.` | `tooling.sh` operates on `TARGET_USER`'s account — run `setup.sh` (at least the `user` step) first. |
| `Reboot required before the remaining steps (…)` then it stops | Expected: `upgrade` pulled a new kernel. Reboot, reconnect over the tailnet, re-run `tooling.sh` — `upgrade` is now a no-op and the tools install. See [tooling](tooling.md). |
| `docker` works only with `sudo` after install | Group membership needs a fresh login. Open a **new** SSH session (the script warns about this). |
| `system python3 is <ver> (< 3.12)` warning | The box's release ships an older Python (e.g. 22.04 → 3.10). Provision Ubuntu 24.04, or `uv python install 3.12`. |

## Provisioning (`provision-hetzner.sh`)

| Message | Fix |
|---|---|
| `hcloud CLI not found.` | Install the [`hcloud` CLI](https://github.com/hetznercloud/cli). |
| `hcloud is not authenticated.` | `hcloud context create <name>` (needs an API token). |
| `HCLOUD_SSH_KEY is empty.` | Set it to a key name already in your hcloud account (`hcloud ssh-key list`). |
| `SSH key '<name>' not found in hcloud.` | Use one of the names the error lists, or add your key to the account first. |
| `SSH on <ip>:22 did not come up in time.` | The box was created but isn't answering SSH yet. Check the Hetzner console; re-run (it's idempotent — it won't recreate an existing box). |

## SSH alias (`ssh-alias.sh`, local)

| Message | Fix |
|---|---|
| `tailscale CLI not found (PATH or Tailscale.app).` | Install Tailscale on **your** machine — the alias is resolved from your local tailnet view, not the box. |
| `'<name>' not on the tailnet — bootstrap/join the box first` | The box hasn't joined yet (or has a different `TS_HOSTNAME`). Bootstrap it first, then re-run. Pass the tailnet name as the first arg if it differs from the alias. |

## Secrets got stripped under `sudo`

If you passed `SUDO_PASSWORD` / `TS_AUTHKEY` as environment variables and the run
warns they're missing, `sudo`'s `env_reset` stripped them. Either use `sudo -E`, or
(preferred) put them in `config.env` — it survives `env_reset`. Preflight warns
about exactly this case.
