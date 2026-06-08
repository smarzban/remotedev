# Provisioning a Hetzner box (`provision-hetzner.sh`)

Optional, **provider-specific** helper. It does **one** job: *create* the VPS
(idempotently) and wait until SSH is reachable — then hands off to the
provider-agnostic scripts. It does **not** harden; that's [`setup.sh`](running-remotely.md).

Other providers: skip this entirely. Create the box however you like (with your
SSH key for initial root), then start at `setup.sh`.

## Requirements

- The [`hcloud` CLI](https://github.com/hetznercloud/cli), authenticated:
  `hcloud context create <name>` (needs an API token).
- `HCLOUD_SSH_KEY` set to a key name already in your hcloud account
  (`hcloud ssh-key list`). See the [config reference](configuration.md).

## Usage

```bash
cp config.env.example config.env
$EDITOR config.env                          # set HCLOUD_SSH_KEY (+ type/location/name)
CHECK=1 ./provision-hetzner.sh              # dry run: show the plan, create nothing
./provision-hetzner.sh                      # create the box (idempotent: skips if it exists)
COPY_TOOLKIT=true ./provision-hetzner.sh    # also scp the scripts + config.env over
HCLOUD_SERVER_TYPE=cax21 ./provision-hetzner.sh   # override any setting via env
```

Reads `HCLOUD_*` from `config.env` (or env-var overrides). On success it prints the
single next command to run (`setup.sh bootstrap`); each script then prints the one
after it. See [running remotely](running-remotely.md) for the full chain.

## Recycled-IP host keys

Hetzner reuses public IPs. If you recreate a box and the new IP was previously
used by a box you deleted, your local `known_hosts` still has the *old* host key
pinned, and `ssh`/`scp` will refuse with **"REMOTE HOST IDENTIFICATION HAS
CHANGED"**.

`provision-hetzner.sh` handles this automatically: when it **creates** a box (and
only then — `CREATED=1`), it clears any stale `known_hosts` entry for the new IP,
since a key pinned for a freshly-made box is by definition stale. The `accept-new`
on the subsequent `scp`/`ssh` re-pins the real key.

It is gated on *creation* so it never silently drops the pin of a pre-existing box
it didn't make. If you hit the warning for a box that already existed (e.g. you ran
the script, it said "already exists", and the IP collides), clear it by hand once:

```bash
ssh-keygen -R <ip>
```
