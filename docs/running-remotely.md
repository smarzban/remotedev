# Running remotely over SSH

The toolkit is meant to be **driven over SSH** — bootstrap over the public IP, then
reconnect over Tailscale to seal, verify, tool, and clean up. This page is the
reference for the *mechanics* of doing that: the gotchas that bite, the optional
`ssh <name>` shortcut, the bootstrap-window risk, and where secrets live on the box.

For the step-by-step walkthrough — what to run, in order — see the
**[full guide](guide.md)**. Each script also prints the single next command when it
finishes, so in practice you just follow along:

```
get a box → setup.sh bootstrap → (seal over Tailscale) → verify.sh → tooling.sh → cleanup.sh
```

## Three remote-execution gotchas (learned the hard way)

> **Use `ssh -t` for anything with `sudo`.** `sudo` over SSH needs a TTY for the
> password — without `-t` you get *"sudo: a terminal is required"*.

> **Use absolute paths after the seal.** In the phased flow you bootstrap as `root`
> (scripts land in `/root`) but seal/verify/tool as the **sudo user**, whose home
> doesn't have them. Call them by absolute path: `sudo bash /root/<script>`.

> **Keep each remote command on ONE line.** A newline inside the quotes injects a
> literal newline — a bare `sudo bash` then drops you into an interactive root shell
> instead of running the script, and the rest of the command never runs.

Hit a wall — locked out, a step refusing to run, a host-key error? See
[troubleshooting](troubleshooting.md).

## SSH alias (`ssh-alias.sh`)

Tired of typing `ssh -t <user>@<tailscale-ip> -p <port> '…'`? Run the optional
**local** helper once (on your Mac, after the box has joined the tailnet) to add a
`Host <name>` block to `~/.ssh/config`:

```bash
./ssh-alias.sh                 # name/user/port from config.env
./ssh-alias.sh myhost          # override the alias name
CHECK=1 ./ssh-alias.sh         # dry-run
```

Then the whole flow shortens to:

```bash
ssh remotedev
ssh -t remotedev 'sudo bash /root/tooling.sh'
```

It uses the box's **Tailscale IP** as `HostName`, resolved locally from this
machine's tailnet view (`tailscale ip -4 <name>`) — no SSH into the box and no
MagicDNS required. Idempotent (the block lives between sentinel markers and is
rewritten in place), so re-run after a recreate to refresh the IP. `cleanup.sh`
reminds you about it at the end of the flow. Requires the `tailscale` CLI on your
Mac (PATH or the `Tailscale.app` bundle).

## The bootstrap window

The `firewall` step runs **last** (anti-lockout), so between bootstrap and seal a
hardened-but-public sshd is briefly reachable on `SSH_PORT`. Keep a provider
security group / cloud firewall in front of the box during bootstrap; re-running
converges and the seal removes any stray public rules. Use an **ephemeral,
single-use** Tailscale auth key so a captured key is already spent.

## Secrets on the box

`config.env` holds a Tailscale auth key and the sudo password — treat it as
sensitive. The toolkit lands in **root's home (`/root`)** — that's why you call the
scripts by absolute path (`/root/<script>`) once you're the sudo user — and
`config.env` lives there too, `chmod 600`. `COPY_TOOLKIT=true` (and the next-step
`scp … && ssh … 'chmod 600 ~/config.env'` hint) does this for you; do the same if
you `scp` by hand. **Don't** leave it world-readable in `/tmp`. Run
[`cleanup.sh`](cleanup.md) at the end to shred it.
