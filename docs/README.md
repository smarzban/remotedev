# remotedev documentation

`remotedev` takes a fresh Ubuntu/Debian VPS to a **hardened, Tailscale-sealed**
state — inbound allowed only over Tailscale, the public internet sees no open
ports — then optionally lays a dev-tooling layer on top. Provider-agnostic,
idempotent, and driven over SSH by a human or an agent.

New here? Start with the [Quickstart in the top-level README](../README.md#quickstart),
then follow the chain below. Each script prints the single next command when it
finishes, so in practice you copy-paste your way through it:

```
provision → setup.sh bootstrap → (seal over Tailscale) → verify.sh → tooling.sh → cleanup.sh
```

## Who starts where

- **Operating the toolkit** (hardening a box) — work the chain:
  [provisioning](provisioning.md) → [running remotely](running-remotely.md) →
  [configuration](configuration.md) → [tooling](tooling.md) → [cleanup](cleanup.md).
  Stuck? [troubleshooting](troubleshooting.md).
- **Reviewing the security posture** (what this does to a box, and why it can't
  lock you out) — [security model](security-model.md).
- **Working on the toolkit itself** — [`../CLAUDE.md`](../CLAUDE.md): conventions,
  the anti-lockout invariants, and lessons already learned.

## Index

| Doc | What it covers |
|---|---|
| [security-model.md](security-model.md) | The end-state posture, what each layer hardens, and the anti-lockout guarantees. |
| [configuration.md](configuration.md) | Every `config.env` key — hardening, tooling, and Hetzner provisioning — with defaults. |
| [provisioning.md](provisioning.md) | Creating the box with the Hetzner helper (or bring your own VPS). |
| [running-remotely.md](running-remotely.md) | The go-live flow over SSH, the three remote-execution gotchas, and the `ssh-alias.sh` shortcut. |
| [tooling.md](tooling.md) | The optional dev layer: upgrade, Docker, Homebrew, uv, Python, Node. |
| [cleanup.md](cleanup.md) | The final scrub — shred secrets, remove the toolkit. |
| [troubleshooting.md](troubleshooting.md) | Lockout recovery and the failure modes you'll actually hit. |
