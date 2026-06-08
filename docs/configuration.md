# Configuration (`config.env`)

Copy the template and edit it. `config.env` is **git-ignored** and holds secrets
(`SUDO_PASSWORD`, `TS_AUTHKEY`) — never commit it.

```bash
cp config.env.example config.env
$EDITOR config.env
```

Every value can also be supplied as an environment variable. `config.env` is the
canonical path because it survives `sudo`'s `env_reset`; if you'd rather pass
secrets as env vars you **must** use `sudo -E` (otherwise `sudo` strips them and
the run aborts).

## Hardening (`setup.sh` / `verify.sh`)

| Key | Meaning |
|---|---|
| `TARGET_USER` | Non-root sudo user to create/harden (default `deploy`). |
| `SUDO_PASSWORD` | Password for `TARGET_USER` (sudo requires one; SSH stays key-only). If empty, the script prompts interactively. Set as an env var for one-shot runs. |
| `SSH_AUTHORIZED_KEYS` | Public key(s) to authorize, one per line. If empty, existing keys are kept; SSH won't be locked down if the user would have no key. |
| `SSH_PORT` | SSH port (default `2202`; choose your own). |
| `TS_AUTHKEY` | Tailscale auth key — generate at <https://login.tailscale.com/admin/settings/keys>. Use an **ephemeral, single-use, tagged** key. Passed via a `0600` tmpfs file, never on the command line. Required unless `ALLOW_PUBLIC_SSH=true`. |
| `TS_HOSTNAME` | Tailscale machine name (defaults to system hostname). |
| `ALLOW_PUBLIC_SSH` | `false` (default) = public interface fully sealed. `true` = also open `SSH_PORT` publicly (fallback / no-VPN setups). |
| `ALLOW_SSH_FORWARDING` | `false` (default) = TCP/agent/tunnel forwarding disabled. `true` to allow (e.g. IDE port-forwarding). |
| `LOCK_ROOT_PASSWORD` | `true` (default) = lock the root password (only after the user has a key). `false` if your provider console needs root login. |
| `INSTALL_AUDIT` | `false` (default). `true` installs `auditd` with an auth/identity ruleset. |

## Dev tooling (`tooling.sh` only)

All default to `true`; the `upgrade` step always runs. See [tooling](tooling.md).

| Key | Meaning |
|---|---|
| `INSTALL_DOCKER` | Docker CE (signed apt repo) + add `TARGET_USER` to the `docker` group. |
| `INSTALL_BREW` | Homebrew (Linuxbrew), installed as `TARGET_USER`. |
| `INSTALL_UV` | Astral `uv`, installed as `TARGET_USER`. |
| `INSTALL_PYTHON` | System Python base (`python3` + `venv` + `pip` + `dev`). |
| `INSTALL_NODE` | Node.js + `npm` from NodeSource (signed apt repo). |
| `NODE_MAJOR` | Node major to install (e.g. `22` LTS, `24`). |

## Hetzner provisioning (`provision-hetzner.sh` only)

Used only by the local [provisioning helper](provisioning.md) to *create* the box.

| Key | Meaning |
|---|---|
| `HCLOUD_SERVER_NAME` | Server name; also becomes the hostname / Tailscale name. |
| `HCLOUD_SERVER_TYPE` | e.g. `cax11`/`cax21` (ARM, if in stock) or `cx23`/`cx33`/`cpx*` (x86). |
| `HCLOUD_LOCATION` | `fsn1` \| `nbg1` \| `hel1` \| `ash` \| `hil` \| `sin`. |
| `HCLOUD_IMAGE` | OS image (default `ubuntu-24.04` → Python 3.12 baseline). |
| `HCLOUD_SSH_KEY` | **Required.** Name of a key already in your hcloud account (`hcloud ssh-key list`); used for initial root login. |

> The optional [`ssh-alias.sh`](running-remotely.md#ssh-alias-ssh-aliassh) helper
> reuses `HCLOUD_SERVER_NAME` / `TARGET_USER` / `SSH_PORT` from here; it needs no
> config keys of its own.
