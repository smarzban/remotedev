# Dev tooling (`tooling.sh`)

`setup.sh` is security/access only. **`tooling.sh`** is a separate, optional layer
that makes a hardened box useful for development — run it **after** `setup.sh`
(it needs `TARGET_USER` to exist). It shares the same `config.env`, `CHECK=1`
dry-run, and per-step conventions.

```bash
sudo CHECK=1 ./tooling.sh        # dry run
sudo ./tooling.sh                # everything (respecting toggles)
sudo ./tooling.sh docker uv      # only named steps
# steps: upgrade docker brew uv python node
```

| Step | Result |
|---|---|
| **upgrade** | Full `apt-get dist-upgrade` — the one thing `setup.sh` deliberately omits (it only does `update` + relies on unattended-upgrades for *security* patches). Warns if a reboot is required. |
| **docker** | Docker CE from Docker's **signed apt repo** (not `curl\|sh`), service enabled, and `TARGET_USER` added to the `docker` group (so DevPod/IDEs can use the socket without sudo). Writes `/etc/docker/daemon.json` `"ip": "127.0.0.1"` so published ports default to loopback — Docker bypasses UFW, so a bare `-p 8080:80` would otherwise be public. |
| **brew** | Homebrew (Linuxbrew), installed **as `TARGET_USER`** (the installer refuses root) and wired into their login shells. |
| **uv** | Astral `uv`, installed **as `TARGET_USER`** into `~/.local/bin`. Use `uv python install <ver>` for pinned/extra Python versions. |
| **python** | System Python base: `python3` + `venv` + `pip` + `dev` headers + `pipx` + `python-is-python3`. |
| **node** | Node.js + `npm` from NodeSource's **signed apt repo** (same pattern as Docker). Major pinned by `NODE_MAJOR` (default `24`). |

Toggles (in [`config.env`](configuration.md)): `INSTALL_DOCKER`, `INSTALL_BREW`,
`INSTALL_UV`, `INSTALL_PYTHON`, `INSTALL_NODE` (all default `true`; the `upgrade`
step always runs). `NODE_MAJOR` selects the Node major (e.g. `24`, `22`).

> **Security note:** adding `TARGET_USER` to the `docker` group is effectively
> root-equivalent on the host — an accepted trade-off for a single-user dev box.
> Skip it with `INSTALL_DOCKER=false` if you don't need a local container runtime
> (e.g. you run DevPod against a Kubernetes provider instead).

> **Reboot ordering:** `upgrade` runs first. If it pulls a new kernel, `tooling.sh`
> **stops before installing the tools** and asks you to reboot, so the tools land
> on the new kernel. Reboot, reconnect over the tailnet, and re-run — `upgrade` is
> then a no-op and the tool steps proceed. If no reboot is needed, it continues in
> a single pass. (The upgrade lives here, not in `setup.sh`, to keep the security
> core minimal and free of reboot choreography.)
