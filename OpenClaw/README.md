# Homelab Services — OpenClaw, Pi-hole & Unbound (Rootless Podman)

Deployment reference for three rootless-[Podman](https://podman.io/) services running on
this host, each managed as a **systemd Quadlet** unit: **OpenClaw** (personal AI
gateway), **Pi-hole** (DNS ad-blocker + web UI), and **Unbound** (recursive DNS
resolver, Pi-hole's upstream).

Pi-hole and Unbound live in their own separate repository, with the full
reference (prerequisites, migration notes, troubleshooting) at
[`adr41n/PiHole` — `README.md`](https://github.com/adr41n/PiHole/blob/master/README.md).
This document summarizes all three services and gives OpenClaw its primary
deployment record.

## Overview

| Service | Image | Container | Runs as | Ports |
| --- | --- | --- | --- | --- |
| OpenClaw | `localhost/openclaw:local` (built from source) | `openclaw` | dedicated `openclaw` user (uid 1001) | 18789 (gateway/dashboard), 18790 (bridge) |
| Pi-hole | `docker.io/pihole/pihole:latest` | `pihole` | `adrian` | 53 (DNS), 1000 (web UI HTTP), 443 (web UI HTTPS) |
| Unbound | `docker.io/klutchell/unbound:latest` | `unbound` | `adrian` | 5335 (recursive resolver, Pi-hole upstream) |

All three are installed as Podman Quadlet `.container` files under
`~/.config/containers/systemd/` for their respective user, managed via the
systemd **user** instance (`systemctl --user` or
`systemctl --machine <user>@ --user` for the dedicated `openclaw` user), with
lingering enabled so they start without an active login session.

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

# Restart
sudo systemctl --machine openclaw@ --user restart openclaw.service

# Rebuild image after a source update, then restart
cd /KoolApps/OrgDisk/e47db547-25e1-4aa9-834c-7813afcde903/Docker/openclaw/openclaw
git pull
sudo podman build -t openclaw:local -f Dockerfile .
TMP=$(mktemp -p /tmp openclaw-image.XXXXXX.tar)
sudo podman save openclaw:local -o "$TMP" && sudo chmod 644 "$TMP"
sudo -u openclaw env HOME=/home/openclaw podman load -i "$TMP"
sudo rm -f "$TMP"
sudo systemctl --machine openclaw@ --user restart openclaw.service
```

Note: cold start takes roughly a minute (Node/Bun dependency loading) before
the gateway logs "listening on ws://0.0.0.0:18789" — don't assume it has
failed if the dashboard isn't reachable within the first ~60 seconds of a
restart.

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
