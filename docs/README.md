# remotedev documentation

`remotedev` takes a fresh Ubuntu/Debian VPS to a **hardened, Tailscale-sealed**
state — inbound allowed only over Tailscale, the public internet sees no open
ports — then optionally lays a dev-tooling layer on top. Provider-agnostic,
idempotent, and driven over SSH by a human or an agent.

**New here? Read the [full guide](guide.md)** — the complete end-to-end walkthrough
(it works on any Ubuntu/Debian VPS; Hetzner is just an optional shortcut). The
[README quickstart](../README.md#quickstart) is the condensed version. The lifecycle
is a chain, and each script prints the single next command when it finishes:

```
get a box → configure → bootstrap → (seal over Tailscale) → verify → tooling → cleanup
```

## Who starts where

- **Operating the toolkit** (hardening a box) — start with the
  [full guide](guide.md), then dip into the references as needed:
  [configuration](configuration.md), [running remotely](running-remotely.md) (SSH
  mechanics), [provisioning](provisioning.md) (the optional Hetzner helper),
  [tooling](tooling.md), [cleanup](cleanup.md). Stuck? [troubleshooting](troubleshooting.md).
- **Reviewing the security posture** (what this does to a box, and why it can't
  lock you out) — [security model](security-model.md).
- **Working on the toolkit itself** — [`../CLAUDE.md`](../CLAUDE.md): conventions,
  the anti-lockout invariants, and lessons already learned.

## Index

| Doc | What it covers |
|---|---|
| [guide.md](guide.md) | **Start here.** The full end-to-end walkthrough: fresh box → configure → bootstrap → seal → verify → tooling → cleanup. |
| [security-model.md](security-model.md) | The end-state posture, what each layer hardens, and the anti-lockout guarantees. |
| [configuration.md](configuration.md) | Every `config.env` key — hardening, tooling, and Hetzner provisioning — with defaults. |
| [provisioning.md](provisioning.md) | The optional Hetzner create-the-box helper (other providers: bring your own VPS). |
| [running-remotely.md](running-remotely.md) | Driving the toolkit over SSH: the three remote-execution gotchas and the `ssh-alias.sh` shortcut. |
| [tooling.md](tooling.md) | The optional dev layer: upgrade, Docker, Homebrew, uv, Python, Node. |
| [cleanup.md](cleanup.md) | The final scrub — shred secrets, remove the toolkit. |
| [troubleshooting.md](troubleshooting.md) | Lockout recovery and the failure modes you'll actually hit. |
