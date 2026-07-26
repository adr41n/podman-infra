# Plex Remote Access — Configuration & Troubleshooting Reference

**Last updated:** 2026-07-26  
**Server:** `koolapps` · `192.168.0.5` · Ubuntu  
**Plex version:** 1.43.3.10828-00f62d37d  

---

## Problem summary

Plex remote access was unreliable. The primary remote user (Samsung Tizen TV,
`QE55Q7FAAUXXU`, ~95% of remote usage) was silently falling back to **Plex
Relay**, causing stuttering and dropped streams. A `plex-publish.timer`
workaround had been keeping Relay alive as the only functional remote path.

---

## Root cause

The **Plusnet Hub Two** (`192.168.0.254`) has a broken inbound NAT engine.
Port-forward rules, DMZ (which was pre-set to `192.168.0.5`), and UPnP
`AddPortMapping` requests all accept configuration and appear in the router's
table but the firmware generates TCP RST or drops packets rather than
forwarding them to the LAN. Exhaustively confirmed:

- UPnP mappings recorded but all forwarded ports timeout externally.
- Manual port-forward rules created via UI: behavior changed from `timeout` →
  `Connection refused`, proving the Hub Two generates RST itself rather than
  forwarding.
- Confirmed with `ss`-verified listener running on `0.0.0.0:34400` —
  external nodes still received `Connection refused`. RST originates at the
  router, not the host.
- DMZ was pre-existing and also non-functional.
- Affects all ports tested: 32400, 34400, 34000.

**This is a firmware-level defect on ISP-provisioned Hub Two units. It cannot
be resolved from within the LAN without replacing the router or contacting
Plusnet.**

---

## Solution — Tailscale Funnel

Tailscale (v1.98.4, already installed) exposes Plex publicly via its relay
infrastructure. No router involvement, no inbound connections required.

### Public URL

```
https://koolapps.tuxedo-roach.ts.net
```

Traffic path: Internet → Tailscale DERP relay → `tailscaled` on this host →
`http://127.0.0.1:32400` (Plex).

### Enable / disable

```bash
# Re-enable (if ever disabled)
sudo tailscale funnel --bg --https=443 http://127.0.0.1:32400

# Disable
sudo tailscale funnel --https=443 off

# Check status
sudo tailscale funnel status
```

The Funnel config is persistent — it survives reboots and `tailscaled` restarts
automatically. `tailscaled` itself is enabled via systemd (`systemctl is-enabled
tailscaled` → `enabled`).

### Verify

```bash
# From this host (hairpin via Tailscale relay)
curl -s https://koolapps.tuxedo-roach.ts.net/identity

# From any external machine / check-host.net
curl -s https://koolapps.tuxedo-roach.ts.net/identity
# Expect: <MediaContainer ... claimed="1" ...>
```

---

## Access paths by device

| Device | Connection URL | Notes |
|--------|---------------|-------|
| Samsung TV (Tizen) | `https://koolapps.tuxedo-roach.ts.net:8443` | No Tailscale needed. Plex advertises this automatically. |
| iPhone / iPad (Tailscale) | `https://100-84-197-119.b0cdeef7cc6d4b5b84d0edfcc0fca232.plex.direct:32400` | Plex discovers this automatically when Tailscale is connected. Direct P2P — fastest path. |
| Other laptops / Linux (Tailscale) | `http://100.84.197.119:32400` | Direct Tailscale IP, no relay. |
| LAN devices | `https://192-168-0-5.b0cdeef7cc6d4b5b84d0edfcc0fca232.plex.direct:32400` | Direct LAN via plex.direct HTTPS. |
| Fallback | Plex Relay | Still enabled (`RelayEnabled="1"`). Used if all above fail. |

### Remote client quality settings (buffering fix)

This server has **no hardware GPU** (Matrox G200eW is a BMC display chip — not
capable of video acceleration). All transcoding is CPU-only. To avoid buffering
on remote streams:

1. **On each remote Plex client:** Settings → Quality → Remote Streaming →
   set to **8 Mbps 1080p** or lower. This ensures Plex transcodes the stream
   to a bitrate the connection can sustain rather than attempting to deliver
   full source quality (which can be 20–40 Mbps for HEVC).
2. **Best option — join Tailscale:** Tailscale-connected devices get a direct
   P2P connection (`100.84.197.119:32400`) at LAN-equivalent speed, bypassing
   all relays. Install the Tailscale app and connect to `tuxedo-roach.ts.net`.
3. **Direct play where possible:** If the remote device can decode HEVC natively
   (most modern TVs, Apple devices, Android), ensure "Allow Direct Play" is
   enabled in the client to avoid CPU transcoding entirely.

---

## Plex Preferences.xml — remote access settings

Location (host): `/home/adrian/Podman/Plex/config/Library/Application
Support/Plex Media Server/Preferences.xml`

| Key | Value | Notes |
|-----|-------|-------|
| `ManualPortMappingMode` | `1` | Manual port mapping enabled |
| `ManualPortMappingPort` | `8443` | Matches Tailscale Funnel port; plex.tv verifies via `koolapps.tuxedo-roach.ts.net:8443` |
| `PublishServerOnPlexOnlineKey` | `1` | Server published to plex.tv |
| `RelayEnabled` | `1` | Relay fallback enabled |
| `customConnections` | `https://koolapps.tuxedo-roach.ts.net, http://100.84.197.119:32400` | Funnel (public) + direct Tailscale IP |

### What plex.tv advertises to clients

Verified 2026-07-26 via `plex.tv/api/resources`:

| URI | Type | Who uses it |
|-----|------|-------------|
| `https://192-168-0-5...plex.direct:32400` | Local LAN | Devices on `192.168.0.x` |
| `https://koolapps.tuxedo-roach.ts.net:8443` | Tailscale Funnel | Any internet client, no Tailscale needed |
| `https://100-84-197-119...plex.direct:32400` | Tailscale direct | Devices connected to Tailscale |
| `https://80-189-232-59...plex.direct:8443` | WAN plex.direct | Self-check via iptables loopback (see below) |
| `https://[relay-ip]...plex.direct:8443` | Plex Relay | Fallback for all clients |

---

## PureVPN bypass — plex-novpn.sh

Location: `/usr/local/bin/plex-novpn.sh`  
Managed by: `/etc/systemd/system/plex-novpn.service` (system-level, starts at boot)

Marks outbound Plex traffic with `fwmark 0x64` to route via the `novpn`
routing table (`table 100`), bypassing PureVPN for Plex responses.

Marked ports (as of 2026-07-26):
- TCP: `32400`, `32469`, `34400`, `8443`
- UDP: `1900`, `32410`, `32412`, `32413`, `32414`

Port `8443` added 2026-07-26 — required for Plex relay and Tailscale Funnel
response traffic since `ManualPortMappingPort` was changed to `8443`.  
Port `34400` retained (harmless legacy from port-forward investigation).

---

## plex-publish.timer workaround

Location: `~/.config/systemd/user/plex-publish.timer`  
Script: `~/.config/plex/ensure-publish.sh`

Periodically re-asserts `PublishServerOnPlexOnlineKey=1` to prevent Plex from
disabling publishing when it cannot confirm direct reachability.

**This workaround is no longer critical** since the Tailscale Funnel provides
a stable path. It can be disabled:

```bash
systemctl --user disable --now plex-publish.timer
```

Leave enabled if you want belt-and-braces insurance.

---

## Plex container

Managed by Podman Quadlet (rootless, user-level systemd):

```
~/.config/containers/systemd/plex.container
```

```bash
# Start / stop / restart
systemctl --user start plex
systemctl --user stop plex
systemctl --user restart plex

# Logs
journalctl --user -u plex -f

# Status
podman ps --filter name=plex
```

Image: `lscr.io/linuxserver/plex` (auto-update enabled via `AutoUpdate=registry`)  
Network: `host` (Plex binds directly to `*:32400` on the host)  
Config volume: `/home/adrian/Podman/Plex/config`

---

## Tailscale

Tailnet: `tuxedo-roach.ts.net`  
Account: `adr41n@`  
This node: `koolapps` · `100.84.197.119` · `fd7a:115c:a1e0::a38:c578`  
MagicDNS: `koolapps.tuxedo-roach.ts.net`

```bash
# Status
tailscale status

# Bring up (if offline)
sudo tailscale up

# Ping a remote device
tailscale ping <device-name>
```

---

## iptables NAT loopback (hairpin NAT workaround)

The Plusnet Hub Two does not support hairpin/loopback NAT. Plex's hourly
self-reachability check (`GET https://{WAN-IP}.plex.direct:{port}/identity`)
would fail immediately because the router sends TCP RST for outbound traffic
trying to re-enter via the WAN IP.

A local DNAT rule intercepts this traffic and redirects it to Plex directly:

```bash
# Active rule (OUTPUT chain, nat table)
# Redirects ALL TCP from this host to the WAN IP → localhost:32400
iptables -t nat -A OUTPUT -d 80.189.232.59 -p tcp -j DNAT --to-destination 127.0.0.1:32400
```

Required sysctl (allows DNAT to loopback address):

```bash
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.bond0.route_localnet=1
net.ipv4.conf.default.route_localnet=1
```

**Persistence:** Managed by `plex-nat-loopback.service` (system-level systemd)
and `/etc/sysctl.d/99-plex-nat.conf`.

```bash
# Check
sudo iptables -t nat -L OUTPUT -n | grep 80.189.232.59
systemctl status plex-nat-loopback
```

**Note:** If the WAN IP changes, update the rule in
`/etc/systemd/system/plex-nat-loopback.service` and
`/usr/local/bin/plex-novpn.sh`.

---

## Tailscale Funnel

### Public URLs

```
https://koolapps.tuxedo-roach.ts.net       (port 443  — primary)
https://koolapps.tuxedo-roach.ts.net:8443  (port 8443 — plex.tv verification)
```

Both proxy to `http://127.0.0.1:32400`. Port 8443 is required because
`ManualPortMappingPort=8443` causes plex.tv to verify the server at
`koolapps.tuxedo-roach.ts.net:8443` — which must be reachable.

### Enable / disable

```bash
# Enable both ports
sudo tailscale funnel --bg --https=443 http://127.0.0.1:32400
sudo tailscale funnel --bg --https=8443 http://127.0.0.1:32400

# Disable
sudo tailscale funnel --https=443 off
sudo tailscale funnel --https=8443 off

# Check status
tailscale funnel status
```

---

## Outstanding actions

- [x] ~~Add `https://koolapps.tuxedo-roach.ts.net` as custom server URL in Samsung TV's Plex app.~~ Now advertised automatically via plex.tv.
- [x] ~~Disable `plex-publish.timer`.~~ Still running as belt-and-braces insurance.
- [ ] **Optional:** Contact Plusnet support about broken port-forwarding on
  the Hub Two. If ever fixed, set `ManualPortMappingPort=32400`, remove the
  iptables loopback rule, and re-add port `32400` to `plex-novpn.sh`.
- [ ] **Buffering:** Advise all remote users to set Plex client quality to
  ≤8 Mbps, or install Tailscale for direct P2P streaming.

---

## Config archive

A snapshot of all modified/relevant config files as of 2026-06-23 is in:

```
/home/adrian/Podman/Plex/remote-access-archive-2026-06-23/
```

Files archived: `plex-novpn.sh`, `plex-novpn.service`, `plex.container`,
`plex-publish.service`, `plex-publish.timer`, `ensure-publish.sh`,
`Preferences.xml`, `tailscale-funnel-status.txt`
