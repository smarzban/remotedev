# The full guide

This is the end-to-end walkthrough: from a fresh VPS to a **hardened,
Tailscale-sealed** box (optionally with a dev-tooling layer), start to finish. If
you just want the shortest path, the [README quickstart](../README.md#quickstart)
is the condensed version of this page.

The toolkit is **provider-agnostic** — it runs on any Ubuntu/Debian VPS you can SSH
into as root. [Hetzner](provisioning.md) has an optional create-the-box helper, but
that's a convenience, not a requirement; **most of this guide assumes you already
have a box**.

The lifecycle is a chain, and each script prints the single next command when it
finishes — so in practice you run one thing and follow the prompt:

```
get a box → configure → bootstrap → seal (over Tailscale) → verify → tooling → cleanup
```

## Before you start

You need:

- **A target VPS** running **Ubuntu 24.04** (22.04 works too; 24.04 gives a Python
  3.12 baseline) that you can `ssh root@<host>` into. Any provider.
- **A Tailscale account** and an auth key — generate an **ephemeral, single-use,
  tagged** key at <https://login.tailscale.com/admin/settings/keys>.
- **Your SSH public key** — it gets authorized on the box; password SSH is disabled.
- The toolkit itself, on your local machine (this repo).

> **Safety during setup.** Until the firewall seals (step 4), a hardened-but-public
> sshd is briefly reachable on your chosen port. Keep a provider security group /
> cloud firewall in front of the box during this window, and use a single-use
> Tailscale key so a captured key is already spent. More in
> [running remotely → the bootstrap window](running-remotely.md#the-bootstrap-window).

## 1. Configure

Copy the template and fill it in. `config.env` is **git-ignored** and holds secrets
— never commit it.

```bash
cp config.env.example config.env && $EDITOR config.env
```

The values you'll almost always set:

- `SSH_AUTHORIZED_KEYS` — your SSH public key(s), one per line.
- `SUDO_PASSWORD` — a password for the sudo user (SSH stays key-only; this is for
  `sudo` and the console).
- `TS_AUTHKEY` — your Tailscale auth key.
- `SSH_PORT` — a non-standard port (default `2202`); `TARGET_USER` — the sudo user
  to create (default `deploy`).

Every key is documented in the [configuration reference](configuration.md).

## 2. Get a box and copy the toolkit onto it

**Bring your own VPS (any provider).** Create an Ubuntu box with your SSH key for
root, then copy the toolkit + your `config.env` to root's home and lock down the
secrets file:

```bash
scp setup.sh verify.sh tooling.sh cleanup.sh config.env root@<host>:~/
ssh root@<host> 'chmod 600 ~/config.env && chmod +x ~/*.sh'
```

> The toolkit lands in **root's home (`/root`)**. That's why, once you're the sudo
> user in later steps, you call the scripts by absolute path (`/root/<script>`).
> `ssh-alias.sh` is **not** copied — it's a local helper (step 7).

**On Hetzner (optional shortcut).** [`provision-hetzner.sh`](provisioning.md) creates
the box *and* copies the toolkit for you in one step — set the `HCLOUD_*` keys in
`config.env` first:

```bash
COPY_TOOLKIT=true ./provision-hetzner.sh
```

Either way, you end up with a box you can `ssh root@<host>` into, with the scripts
and `config.env` in `/root`.

## 3. Bootstrap over the public IP

`bootstrap` runs **every hardening step except the firewall seal** — it creates the
sudo user, installs and joins Tailscale, hardens sshd (key-only, custom port,
standalone — not socket-activated), and sets up fail2ban, unattended-upgrades,
AppArmor, sysctl hardening, and persistent journald. Run it as root:

```bash
ssh root@<host> './setup.sh bootstrap'
```

When it finishes it prints the **seal** command next, pre-filled with the box's new
Tailscale IP. (Prefix any run with `CHECK=1` to preview without changing anything:
`ssh root@<host> 'CHECK=1 ./setup.sh bootstrap'`.)

Why the firewall isn't part of `bootstrap`: sealing is the lockout-sensitive step,
so it runs **last**, from a Tailscale session — see the next step.

## 4. Reconnect over Tailscale and seal the firewall

The seal closes the public interface so the box is reachable **only over Tailscale**.
To avoid locking yourself out, `setup.sh firewall` refuses to run unless Tailscale is
up *and* your current session is on the tailnet — so you must reconnect over the
**Tailscale IP** first (not the public one), as the sudo user:

```bash
ssh -t <user>@<tailscale-ip> -p <port> 'sudo bash /root/setup.sh firewall'
```

Three remote-execution details bite here — `ssh -t` for `sudo`, **absolute** script
paths, and keeping the command on **one line**. They're explained in
[running remotely](running-remotely.md#three-remote-execution-gotchas-learned-the-hard-way).
The seal prints the verify command next.

## 5. Verify the posture

A read-only audit of everything that should now be true (sshd hardened, firewall
sealed, Tailscale running, fail2ban/auto-updates/AppArmor/sysctl in place). It
**exits non-zero on any failure** — run it *before* you disconnect:

```bash
ssh -t <user>@<tailscale-ip> -p <port> 'sudo bash /root/verify.sh'
```

On a clean pass it prints the tooling command next. What each check asserts is
described in the [security model](security-model.md).

## 6. Install dev tooling (optional)

`tooling.sh` is the separate dev-host layer — Docker, Homebrew, uv, Python, Node —
kept out of the security core. Run it after the box is sealed and verified:

```bash
ssh -t <user>@<tailscale-ip> -p <port> 'sudo bash /root/tooling.sh'
```

> **Reboot gate.** If the bundled `upgrade` step pulls a new kernel, `tooling.sh`
> stops and asks you to reboot before laying the tools on top. Reboot, reconnect
> over the tailnet, and re-run — `upgrade` is then a no-op and the tools install.
> Full detail (and the per-tool toggles) in [tooling](tooling.md).

## 7. Clean up

Run last. `cleanup.sh` shreds `config.env` and removes the toolkit scripts and run
logs from the box — leaving the hardened box itself untouched:

```bash
ssh -t <user>@<tailscale-ip> -p <port> 'sudo bash /root/cleanup.sh'
```

See [cleanup](cleanup.md) for exactly what it removes and why it's a separate step.

## Optional: an `ssh <name>` shortcut

Tired of `ssh -t <user>@<tailscale-ip> -p <port> '…'`? Run the **local** helper once
(on your own machine, after the box has joined the tailnet) to add a `Host` block to
`~/.ssh/config`:

```bash
./ssh-alias.sh        # name/user/port from config.env; resolves the Tailscale IP locally
```

Then it's just `ssh <name>`. Details in
[running remotely → ssh alias](running-remotely.md#ssh-alias-ssh-aliassh).

## If something goes wrong

Locked out, a step refusing to run, a host-key error, `sudo: a terminal is
required`? Every failure mode and its fix is in [troubleshooting](troubleshooting.md).
The short version: the scripts fail safe, every step is idempotent, and re-running
converges — so the fix is almost always "satisfy the guard and re-run the step."
