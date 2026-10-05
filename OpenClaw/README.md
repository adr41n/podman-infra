# Homelab Services — Rootless Podman Deployment Reference

Deployment reference for this host's rootless-[Podman](https://podman.io/)
containers, covering **OpenClaw** (personal AI gateway), **Pi-hole** (DNS
ad-blocker + web UI), **Unbound** (recursive DNS resolver, Pi-hole's
upstream), **Dispatcharr**, and the auto-start/auto-update configuration
shared by every container on the host (11 total, across two systemd user
instances).

Pi-hole and Unbound live in their own separate repository, with the full
reference (prerequisites, migration notes, troubleshooting) at
[`adr41n/PiHole` — `README.md`](https://github.com/adr41n/PiHole/blob/master/README.md).
This document summarizes those two plus Dispatcharr, and gives OpenClaw its
primary deployment record.

## Overview

| Service | Image | Container | Runs as | Ports |
| --- | --- | --- | --- | --- |
| OpenClaw | `localhost/openclaw:local` (built from source) | `openclaw` | dedicated `openclaw` user (uid 1001) | 18789 (gateway/dashboard), 18790 (bridge) |
| Pi-hole | `docker.io/pihole/pihole:latest` | `pihole` | `adrian` | 53 (DNS), 1000 (web UI HTTP), 443 (web UI HTTPS) |
| Unbound | `docker.io/klutchell/unbound:latest` | `unbound` | `adrian` | 5335 (recursive resolver, Pi-hole upstream) |
| Dispatcharr | `ghcr.io/dispatcharr/dispatcharr:latest` | `dispatcharr` | `adrian` (via podman-compose) | 9191 |
| homeassistant, mosquitto, nodered, plex, rustdesk-hbbr, rustdesk-hbbs, syncthing | various | same names | `adrian` | see each Quadlet |

All Quadlet-managed containers are installed as `.container` files under
`~/.config/containers/systemd/` for their respective user, managed via the
systemd **user** instance (`systemctl --user` or
`systemctl --machine <user>@ --user` for the dedicated `openclaw` user), with
lingering enabled for both `adrian` and `openclaw` so everything starts
without an active login session.

## Auto-Start & Auto-Update (All Containers)

**Auto-start:** every container's Quadlet (or, for Dispatcharr, its
`dispatcharr-compose.service`) has `[Install] WantedBy=default.target`, so
the systemd generator starts it at boot/login automatically — no manual
`systemctl enable` needed (and doesn't apply to quadlet-generated units
anyway; they're transient).

**Auto-update** uses two different mechanisms depending on where the image
comes from:

| Mechanism | Covers | Schedule | How it works |
| --- | --- | --- | --- |
| `podman-auto-update.timer` (built-in, `adrian`'s systemd user instance) | homeassistant, mosquitto, nodered, pihole, plex, rustdesk-hbbr, rustdesk-hbbs, syncthing, unbound, **dispatcharr** (9 Quadlets + 1 compose container) | Daily, ~00:07 | Each container has label `io.containers.autoupdate=registry`; the timer checks the registry for a newer digest and recreates the container in place if found. |
| `openclaw-update.timer` (custom, system-level) | openclaw only | Weekly, Sun ~04:30 | `openclaw:local` is **built from source**, not pulled from a registry, so the built-in mechanism can't apply. See [OpenClaw § Auto-update](#auto-update-pipeline) below for the dedicated pipeline. |

Dispatcharr originally had **no** `io.containers.autoupdate` label at all
(podman-compose doesn't set one by default), so the timer silently skipped
it. Fixed by adding `labels: ["io.containers.autoupdate=registry"]` to
`Dispatcher/docker-compose.yml` and recreating the container.

### Verifying auto-update is working
```bash
# Confirm every adrian-managed container has the label
for c in homeassistant mosquitto nodered pihole plex hbbr hbbs Syncthing unbound dispatcharr; do
  echo -n "$c: "; podman inspect "$c" --format '{{index .Config.Labels "io.containers.autoupdate"}}'
done

# Timer schedule + last run
systemctl --user list-timers podman-auto-update.timer
journalctl --user -u podman-auto-update.service -n 30   # shows each container checked + whether it updated

# OpenClaw's dedicated pipeline
sudo systemctl list-timers openclaw-update.timer
sudo cat /var/lib/openclaw-update/built.tag   # last successfully-deployed stable tag (absent if none yet)
```
Last verified (2026-10-05): all 9 Quadlet containers + dispatcharr carry the
`registry` label and have been checked by `podman-auto-update.service` on 3
consecutive daily runs (Oct 3–5). All 11 containers across both systemd user
instances (`adrian`: 10, `openclaw`: 1) were confirmed running/healthy.

## OpenClaw

**What it is:** a personal AI assistant/gateway (multi-channel messaging,
agent tools, web dashboard). Source repo:
`/KoolApps/OrgDisk/e47db547-25e1-4aa9-834c-7813afcde903/Docker/openclaw/openclaw`
(upstream: `https://github.com/openclaw/openclaw`).

### Isolation model
Runs under a **dedicated, unprivileged system user** (`openclaw`, uid 1001,
`nologin` shell, home `/home/openclaw`) rather than `adrian`'s own account —
this isolates the gateway (which has broad exec/read/write tool access and
holds LLM provider credentials) from the rest of the homelab.

### Deployment steps taken
1. From the repo root, ran the project's own setup script as root/sudo:
   ```bash
   sudo ./setup-podman.sh --quadlet
   ```
   This created the `openclaw` user, enabled lingering
   (`loginctl enable-linger openclaw`), built the image locally
   (`podman build -t openclaw:local -f Dockerfile .`), loaded it into the
   `openclaw` user's Podman store, generated `OPENCLAW_GATEWAY_TOKEN` into
   `/home/openclaw/.openclaw/.env`, wrote a minimal
   `/home/openclaw/.openclaw/openclaw.json` (`{ gateway: { mode: "local" } }`),
   and installed the Quadlet at
   `/home/openclaw/.config/containers/systemd/openclaw.container`.
2. **Fixed two bugs found in the vendored `setup-podman.sh`/Quadlet template**
   (patched only on the deployed file, not upstream):
   - **Path-escaping bug:** the script's `sed` over-escaped `/` in
     `OPENCLAW_HOME` before substituting it into the template, producing
     literal `\/home\/openclaw\/...` in `Volume=`/`EnvironmentFile=` — the
     outer `sed` already used `|` as its delimiter, so escaping `/` was
     unneeded and corrupted the paths. Fixed by rewriting the installed
     paths without the backslashes.
   - **Missing `User=` directive:** the template never sets `User=`, so the
     container defaulted to the image's `node` user (uid 1000), which could
     not read the `openclaw`-owned (uid 1001), `700`-permission config
     directory — causing an immediate "Missing config" crash-loop even
     though the config was valid. Fixed by adding `User=1001:1001` to match
     `run-openclaw-podman.sh`'s behavior (`--user "$(id -u):$(id -g)"`
     alongside `--userns=keep-id`).
3. Reloaded and started the service:
   ```bash
   sudo systemctl --machine openclaw@ --user daemon-reload
   sudo systemctl --machine openclaw@ --user restart openclaw.service
   ```

### Final Quadlet (`/home/openclaw/.config/containers/systemd/openclaw.container`)
```ini
[Unit]
Description=OpenClaw gateway (rootless Podman)

[Container]
Image=openclaw:local
ContainerName=openclaw
UserNS=keep-id
User=1001:1001
Volume=/home/openclaw/.openclaw:/home/node/.openclaw
EnvironmentFile=/home/openclaw/.openclaw/.env
Environment=HOME=/home/node
Environment=TERM=xterm-256color
PublishPort=18789:18789
PublishPort=18790:18790
Pull=never
Exec=node dist/index.js gateway --bind lan --port 18789

[Service]
TimeoutStartSec=300
Restart=on-failure

[Install]
WantedBy=default.target
```

### Config & data
| Path (on host, as `openclaw` user) | Purpose |
| --- | --- |
| `/home/openclaw/.openclaw/openclaw.json` | Gateway config (`gateway.mode=local`) |
| `/home/openclaw/.openclaw/.env` | `OPENCLAW_GATEWAY_TOKEN` (generated, keep secret) |
| `/home/openclaw/.openclaw/workspace/` | Agent workspace |
| `/home/openclaw/run-openclaw-podman.sh` | Launch script (manual run / onboarding wizard) |

### Access instructions
1. Open `http://192.168.0.5:18789/` in a browser.
2. Paste the gateway token into the Control UI (Settings → token):
   ```bash
   sudo grep OPENCLAW_GATEWAY_TOKEN /home/openclaw/.openclaw/.env
   ```
3. Approve the browser as a paired device if prompted (first connection only).
4. **Run onboarding** to configure an LLM provider and messaging channels
   (deployment only set the minimal `gateway.mode=local`):
   ```bash
   sudo -u openclaw /home/openclaw/run-openclaw-podman.sh setup
   ```
5. If you see "unauthorized" or "pairing required", fetch a fresh dashboard
   link:
   ```bash
   sudo -u openclaw env HOME=/home/openclaw podman exec openclaw node dist/index.js dashboard --no-open
   ```

### Common operations
```bash
# Status / logs
sudo systemctl --machine openclaw@ --user status openclaw.service
sudo -u openclaw env XDG_RUNTIME_DIR=/run/user/1001 journalctl --user -u openclaw.service -f
sudo -u openclaw env HOME=/home/openclaw podman logs -f openclaw

# Restart (no rebuild)
sudo systemctl --machine openclaw@ --user restart openclaw.service
```

Note: cold start takes roughly a minute (Node/Bun dependency loading) before
the gateway logs "listening on ws://0.0.0.0:18789" — don't assume it has
failed if the dashboard isn't reachable within the first ~60 seconds of a
restart.

### Auto-update pipeline
Since `openclaw:local` is built from source (not pulled from a registry),
Podman's built-in `AutoUpdate=registry` label mechanism can't detect or apply
upstream updates for it. A dedicated pipeline handles this instead:

| Component | Path | Purpose |
| --- | --- | --- |
| `openclaw-update.sh` | `/usr/local/sbin/openclaw-update.sh` | Root-run script: fetch tags → build → load → restart → health-check → rollback-on-failure |
| `openclaw-update.service` + `.timer` | `/etc/systemd/system/` | System-level (not user) oneshot + weekly timer (Sun ~04:30, `TimeoutStartSec=infinity`) |
| Build clone | `/var/lib/openclaw-update/src` | **Isolated** clone, separate from the interactive dev checkout — the script must never mutate that checkout's branch/HEAD since it may be in active use when the timer fires |
| Marker files | `/var/lib/openclaw-update/built.{rev,tag}` | Last **successfully health-checked** commit/tag (only written after a passing health check, not merely after a successful build) |

Key design points, each added after hitting a real failure during setup:
- **Tracks the latest stable release tag** (`vYYYY.M.D`, via
  `git tag --sort=-v:refname`), not the moving `main` branch — jumping
  straight to `main` HEAD risks landing on a commit that requires a staged
  data migration the current deployment hasn't gone through yet.
- **Health check is real HTTP + the correct restart counter**: it curls the
  dashboard URL and checks systemd's `NRestarts` (`systemctl ... show -p
  NRestarts`) — **not** `podman inspect --format {{.RestartCount}}`, which is
  always `0` here regardless of crash-looping, because the Quadlet uses `--rm`
  + `Restart=on-failure`, so every crash creates a brand-new container rather
  than incrementing podman's own counter.
- **Automatic rollback on failure**: if the dashboard doesn't respond, or the
  restart count climbs, within the check+settle window, the script re-tags
  the previous image back to `openclaw:local`, restarts, and exits non-zero
  without updating the marker — so a failed run is retried on the next
  scheduled timer, and the gateway is never left down overnight unattended.

#### Known incident: staged-migration guard (2026-10-05)
The first real update attempt (tag `v2026.9.8`) failed to start against the
existing deployment (originally `v2026.2.23`), surfacing two guards in
sequence:
1. `Cron state: retired files whose last writer predates July 1, 2026: .../cron/jobs.json ... Upgrade through OpenClaw 2026.9.7, run "openclaw doctor --fix" on the original host, then retry this upgrade.`
2. After working around the first by inspecting manually: `StartupMaintenanceRequiredError: ... Legacy workspace setup state requires migration at .../workspace-state.json.`

The automatic rollback caught both and restored service each time — but
**advancing the actual deployed version still requires manual intervention**:
follow the staged-upgrade instructions in the error message (intermediate
version + `openclaw doctor --fix`) before the automated pipeline can carry it
the rest of the way. Check `sudo journalctl -u openclaw-update.service` and
`sudo -u openclaw env HOME=/home/openclaw podman logs openclaw` for the exact
guard message if a scheduled run ever reports failure.

#### Manual commands
```bash
# Trigger an update check immediately instead of waiting for the timer
sudo systemctl start openclaw-update.service
sudo journalctl -u openclaw-update.service -f

# Check what's currently deployed vs. the latest available stable tag
sudo cat /var/lib/openclaw-update/built.tag
cd /var/lib/openclaw-update/src && sudo git tag --list 'v*' --sort=-v:refname | head -5

# Disable/re-enable the automated pipeline
sudo systemctl disable --now openclaw-update.timer
sudo systemctl enable --now openclaw-update.timer
```

## Pi-hole & Unbound (summary)

Full reference: [`adr41n/PiHole` — `README.md`](https://github.com/adr41n/PiHole/blob/master/README.md)
(separate repository, not part of `podman-infra`).

- **Pi-hole** filters DNS and serves the admin web UI; **Unbound** runs as a
  separate container providing recursive, DNSSEC-validated resolution on
  `127.0.0.1:5335`, used as Pi-hole's sole upstream
  (`FTLCONF_dns_upstreams=127.0.0.1#5335`).
- Both use `Network=host` and run under `adrian`'s own rootless Podman
  (Quadlets at `~/.config/containers/systemd/{PiHole,Unbound}.container`).
- DNS is bound to the LAN interface only (`FTLCONF_dns_interface=bond0`,
  `listeningMode=BIND`) to avoid colliding with other host DNS listeners.
- The web UI (`FTLCONF_webserver_port`) is explicitly bound to bond0's static
  IP (`192.168.0.5:1000,192.168.0.5:443s`) rather than the wildcard address,
  since this host's Tailscale Funnel already holds a specific bind on port
  443 for Plex.
- Unbound's `HealthCmd` must use the JSON exec-array form
  (`["/usr/bin/drill", "-p", "5335", "@127.0.0.1", "dnssec.works"]`) because
  `klutchell/unbound` is a distroless image with no `/bin/sh`, so the default
  shell-wrapped health check always fails silently.

### Access instructions
- Web UI: `http://192.168.0.5:1000/admin/` or `https://192.168.0.5/admin/`
  (self-signed cert), log in with `FTLCONF_webserver_api_password` from
  `PiHole/.env`.
- Point your router/devices' DNS server at `192.168.0.5`.

### Common operations
```bash
systemctl --user status Unbound.service PiHole.service
systemctl --user restart Unbound.service   # restart Unbound first
systemctl --user restart PiHole.service    # PiHole Requires=Unbound.service

# Verify
dig @192.168.0.5 pi-hole.net +short          # resolves
dig @192.168.0.5 doubleclick.net +short      # 0.0.0.0 (blocked)
podman inspect unbound --format '{{.State.Health.Status}}'   # healthy
```
