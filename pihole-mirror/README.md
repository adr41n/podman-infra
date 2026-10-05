# Pi-hole & Unbound — Mirrored Configuration

This directory **mirrors** the non-secret Quadlet and Unbound configuration
files from the canonical repository:

**Canonical source: [`adr41n/PiHole`](https://github.com/adr41n/PiHole)**
(full README, prerequisites, migration notes, troubleshooting, and helper
scripts live there — edit and commit changes **there**, not here).

## What's mirrored

| File | Purpose |
| --- | --- |
| `PiHole.container` | Pi-hole v6 Podman Quadlet (rootless, host networking) |
| `Unbound.container` | Unbound recursive resolver Quadlet (Pi-hole's upstream) |
| `unbound/pi-hole.conf` | Unbound drop-in config (listening port, Plex private-domain allowance) |
| `.env.example` | Template for the secrets file (`TZ`, web UI password, conditional forwarding) |

## What's intentionally NOT mirrored

- `.env` — the real secrets file (web UI password, etc.). Never committed
  anywhere; lives only on the host at `/home/adrian/Podman/PiHole/.env`.
- `etc-pihole/`, `etc-dnsmasq.d/` — live, mutable container data (gravity DB,
  blocklists, dnsmasq overrides).
- `chkport` — a large local build artifact, unrelated to configuration.

## Why a mirror (and why this directory isn't named `PiHole/`)

Pi-hole/Unbound were already tracked in their own dedicated repository before
`podman-infra` existed. `/home/adrian/Podman/PiHole/` on this host is that
repository's own working directory (it has its own `.git`), so a same-named
directory can't also exist here. This mirror exists purely so the
`podman-infra` repo has a self-contained reference to the DNS stack's
configuration alongside OpenClaw's; **treat the canonical repo as the source
of truth** and re-copy these files here after making real changes there.

Deployment steps, access instructions, and troubleshooting:
[`../OpenClaw/README.md`](../OpenClaw/README.md#pi-hole--unbound-summary) and
the canonical repo's own `README.md`.
