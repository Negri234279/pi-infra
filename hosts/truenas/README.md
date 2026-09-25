# TrueNAS SCALE observability (`hosts/truenas/`)

Monitors the **TrueNAS SCALE 25.10 "Goldeye"** NAS (`192.168.1.18`, panel `nas-web.negri.es`)
from the hub's Prometheus + Grafana. This is the OS/ZFS side; the BMC/IPMI side is separate
(`core/ipmi-exporter/`, job `ipmi`).

This directory holds a **standalone compose that runs ON the NAS** (its native Docker), not on
the hub — the same pattern as `hosts/rpi3/`. It is **not** part of the hub's root `include:` and
is never brought up by `./scripts/deploy.sh`; the Ansible playbook deploys it to the NAS. Only the
hub-side pieces (Prometheus job, alerts, Grafana dashboards) live under `core/`.

## Why this path

TrueNAS's built-in reporting **is netdata**, which already instruments everything on the box
(ZFS pools + ARC, per-disk SMART/temperatures, sensors, CPU/RAM/network, and the Docker apps).
But the only **native, supported** way to export it is the **Graphite** line protocol — there is
no built-in Prometheus endpoint, and the netdata web UI was removed in 25.04+.

So we bridge it:

```
TrueNAS netdata ──(Reporting Exporter, GRAPHITE push, :9109)──► graphite_exporter (container on
  the NAS, TrueNAS mapping baked in) ──(:9108 /metrics)──► hub Prometheus (job `truenas`,
  scraped over the LAN at 192.168.1.18:9108) ──► Grafana (folder "nas")
```

The exporter image is
[`Supporterino/truenas-graphite-to-prometheus`](https://github.com/Supporterino/truenas-graphite-to-prometheus)
— `graphite_exporter` with a TrueNAS-specific `graphite_mapping.conf` compiled in, so metrics
land as `zfs_pool`, `disk_temperature`, `cpu_temperature`, `truenas_arcstats`, `disk_bytes_used`,
etc., all labelled `job="truenas"` (the mapping keys off the `truenas.` prefix — do not change it).

SNMP was rejected (it can't see ZFS/SMART) and a standalone Graphite/Whisper TSDB was rejected
(redundant with the existing Prometheus).

## Pieces

| Where | What | Managed by |
|-------|------|------------|
| TrueNAS (midclt) | netdata → Graphite Reporting Exporter | `ansible/roles/truenas_reporting_exporter` |
| TrueNAS (Docker) | `graphite-exporter` container (`docker-compose.yml`) | `ansible/roles/truenas_docker_stack` |
| Hub Prometheus | job `truenas` (`192.168.1.18:9108`) | `core/prometheus/prometheus.yml` |
| Hub Prometheus | alerts (group `truenas`) | `core/prometheus/rules/truenas-alerts.yml` |
| Hub Grafana | dashboards (folder "nas") | `core/grafana/dashboards/nas/truenas-*.json` |

## Provision

From the hub (`~/pi-infra/ansible`):

```bash
./run.sh playbooks/bootstrap-truenas.yml            # everything
./run.sh playbooks/bootstrap-truenas.yml --tags reporting   # just the netdata exporter
./run.sh playbooks/bootstrap-truenas.yml --tags docker      # just the container
```

Prerequisites:
- **SSH enabled** on TrueNAS with the hub's key authorized for `truenas_admin` (see the `nas`
  group in `ansible/inventory/hosts.yml`).
- **Apps/Docker initialised with a pool** (Apps must be pointed at a data pool once in the UI),
  otherwise there is no Docker engine for `truenas_docker_stack` to use.
- `truenas_apps_dir` in `ansible/inventory/group_vars/nas.yml` set to a real path on your pool.

Then, on the hub, pick up the new Prometheus job + rules + dashboards with `./scripts/deploy.sh`
from the repo root.

## Nextcloud (private Drive) — opt-in

A self-contained Nextcloud (own Postgres + Redis, so it does NOT depend on the hub's shared
Postgres) runs on the NAS for a Google-Drive-like cloud, **LAN/VPN only** (no public exposure).
Files live on dedicated ZFS datasets (`<pool>/nextcloud`, `<pool>/nextcloud-db`) so they get
snapshots.

```bash
cp hosts/truenas/nextcloud.env.example hosts/truenas/nextcloud.env   # fill in the passwords
./run.sh playbooks/bootstrap-truenas.yml --tags nextcloud            # deploy (opt-in tag)
```
Then reach it at `http://192.168.1.18:8080` (mgmt LAN / WireGuard) or, for **max transfer speed**,
`http://nas.negri.es:8080` — that name resolves to `10.10.10.13` (the 10 GbE link) in DNS — from
the box wired to the 10G segment (which is isolated, so only the directly-connected host reaches
it). All of `192.168.1.18`, `10.10.10.13` and `nas.negri.es` are in `NEXTCLOUD_TRUSTED_DOMAINS`.
Log in with the admin user from `nextcloud.env`. For full 10G throughput also enable jumbo frames
(MTU 9000) on both NICs of that point-to-point link.

**Logs → Grafana:** the stack includes an Alloy sidecar (`nextcloud-alloy`) that tails
`data/nextcloud.log` (JSON) and pushes it to the hub's Loki (published on `:3100`) with
`job="nextcloud"`, `instance="truenas"`. The role enables the `admin_audit` app + `loglevel=1` so
login/file/share events are recorded. View them in Grafana → folder **nas** → **Nextcloud Logs**
(`core/grafana/dashboards/nas/nextcloud-logs.json`, Loki datasource). Requires the hub's Loki port
change deployed (`core/docker-compose.yml`). Compose: `hosts/truenas/nextcloud.compose.yml` (relative binds
`./html`, `./data`, `../nextcloud-db`). Role: `ansible/roles/truenas_nextcloud`. It is gated behind
the `nextcloud` tag, so a normal observability bootstrap never touches it. `nextcloud.env` is
gitignored (`hosts/**/*.env`). To later add TLS/a hostname, front it with NPM restricted to the
LAN/VPN and set `NEXTCLOUD_OVERWRITEPROTOCOL=https`.

# Media server stack — opt-in

A full media stack runs on the NAS's native Docker, **LAN/VPN only** (no public exposure):
**Jellyfin** (streaming), **Sonarr**/**Radarr** (TV/movies), **Bazarr** (subtitles),
**Jackett** (indexers) + **FlareSolverr** (Cloudflare solver),
**qBittorrent** (downloads, via **gluetun**/AirVPN), **Jellyseerr** (requests — uses the **Seerr** image
`ghcr.io/seerr-team/seerr`, the maintained successor of Jellyseerr; the old `fallenbagel/jellyseerr`
is archived and breaks on current Jellyfin. Service/DNS name kept as `jellyseerr`), and **Cantinarr**
(discovery/requests + assistant over the *arr stack).

- Compose: `hosts/truenas/media.compose.yml`  ·  Role: `ansible/roles/truenas_media` (tag `media`).
- Config: `hosts/truenas/media.env` (copy from `.example`; gitignored via `hosts/**/*.env`).
- Runs on the NAS, deployed **from the hub** like the rest of `bootstrap-truenas.yml`.

### How it fits together

```
qBittorrent ──downloads──► /data/torrents ──hardlink import──► /data/media/{movies,tv}
      ▲                                                              │
   Jackett (indexers)                                            Jellyfin (streaming)
      ▲                                                              ▲
   Sonarr / Radarr ◄── requests ── Jellyseerr / Cantinarr ◄──── users
```

Everything shares one docker bridge (`media`), so the apps reach each other by **container name**
(`jackett:9117`, `sonarr:8989`, `radarr:7878`, and the download client at **`gluetun:8080`** —
qBittorrent runs in gluetun's VPN namespace) — the host ports below are only for you, from the LAN/VPN.

### Storage layout (why one dataset)

Two ZFS datasets, created by the role via `midclt`:
- `<pool>/mediaserver` → the compose project + per-app config (`./config/<app>`), snapshotted.
- `<pool>/media` → the library **and** downloads on **one filesystem**, mounted as `/data` in every
  media container, with subfolders the role creates and `chown`s to `PUID:PGID`:
  ```
  /data/torrents/{complete,incomplete}   (qBittorrent)
  /data/media/movies                     (Radarr library + Jellyfin)
  /data/media/tv                         (Sonarr library + Jellyfin)
  ```
  Downloads and libraries share the **same** dataset on purpose: Sonarr/Radarr then import by
  **hardlink** instead of copying (instant, no double space, seeding continues) — the TRaSH-guide
  layout. Split them across datasets and every import silently falls back to a slow full copy.

### Ports (LAN/VPN, at `192.168.1.18`)

| Service     | Port  | Notes |
|-------------|-------|-------|
| Jellyfin    | 8096  | streaming server |
| Jellyseerr  | 5055  | requests |
| Cantinarr   | 8585  | discovery + assistant |
| Sonarr      | 8989  | TV |
| Radarr      | 7878  | movies |
| Bazarr      | 6767  | subtitles (Spanish, etc.) |
| Jackett     | 9117  | indexers |
| qBittorrent | 8085  | WebUI (remapped off 8080 to avoid clashing with Nextcloud) |
| qBittorrent | 6881  | BitTorrent peer port (tcp+udp) |

## Setup — step by step

### 0. Prerequisites
- The observability bootstrap prerequisites (SSH + key, Apps/Docker initialised with a pool) — see
  **Provision** above. The media stack reuses the same `nas` inventory host and `truenas_pool`.
- Decide the **owner UID/GID** the apps run as. Find it on the NAS: `ssh truenas 'id <user>'`
  (e.g. `truenas_admin`, or a dedicated `apps` user). It must own `<pool>/media`, or the containers
  can't write.

### 1. Create the config file
From the repo root:
```bash
cp hosts/truenas/media.env.example hosts/truenas/media.env
$EDITOR hosts/truenas/media.env      # set PUID / PGID / TZ (the id from step 0)
```
`MEDIA_LIBRARY_HOST_PATH` defaults to `/mnt/tank/media`; change it only if your pool isn't `tank`
(and keep it in sync with `truenas_media_library_dataset` in the role defaults).

### 2. Deploy
From `~/pi-infra/ansible` on the hub:
```bash
./run.sh playbooks/bootstrap-truenas.yml --tags media
```
This creates the datasets + `/data` subfolders, syncs the compose + `.env` to the NAS, and runs
`docker compose up -d`. On the first run it also auto-provisions the homepage widgets (step 5).

### 3. Verify the containers
```bash
ssh truenas 'docker compose -f /mnt/tank/mediaserver/docker-compose.yml ps'   # all Up
```
Then open each WebUI from the LAN/VPN at `192.168.1.18:<port>` (see the ports table).

### 4. Jellyfin first-run wizard
Open `http://192.168.1.18:8096` and complete the setup wizard (create the admin user, skip adding
libraries for now — you'll point them at `/data/media/*` in step 6). This wizard is the one part
that can't be automated, and it must be done before the Jellyfin API key exists.

### 5. Homepage widgets — mostly automatic
The role **auto-fills** the hub's homepage widgets on deploy: it reads `SONARR_KEY`/`RADARR_KEY`
from each app's `config.xml`, `JELLYSEERR_KEY` from Jellyseerr's `settings.json`, and LAN-whitelists
qBittorrent (`truenas_media_lan_subnet`, default `192.168.1.0/24`) so its widget needs no password.
It writes these into the hub's repo-root `.env` and recreates `homepage`. Nothing to do for those.

The **only manual key is Jellyfin's** (it has no file-based key):
1. Jellyfin → **Dashboard → Advanced → API Keys → +**, name it `homepage`.
2. Put it in the hub `.env`: `JELLYFIN_KEY=<the key>`.
3. Recreate homepage from the repo root on the hub: `docker compose up -d homepage`.

Disable all widget auto-provisioning with `truenas_media_provision_homepage: false` (role default is
`true`).

### 6. Wire the *arr stack (in the WebUIs)
Use **container names**, not host ports, for the internal connections:

1. **qBittorrent** (`:8085`) → Options → Downloads → default save path `/data/torrents`
   (and, if you use it, keep incomplete downloads in `/data/torrents/incomplete`). The role already
   allowed the LAN to reach the WebUI without a password; set a real WebUI password here anyway if
   you want, but then also fill `QBITTORRENT_USER`/`PASSWORD` in the hub `.env` for the widget.
2. **Jackett** (`:9117`) → add your indexers; copy each one's **Torznab feed** + the Jackett API key.
   For Cloudflare-protected indexers (e.g. 1337x → "Challenge detected but FlareSolverr is not
   configured"), set Jackett → Settings → **FlareSolverr API URL** = `http://flaresolverr:8191` and
   save (the `flaresolverr` service is in the compose).
3. **Sonarr** (`:8989`) and **Radarr** (`:7878`):
   - Settings → **Download Clients** → add **qBittorrent**, host **`gluetun`**, port `8080`
     (qBittorrent shares gluetun's network namespace, so the container name on the bridge is
     `gluetun`, not `qbittorrent`).
   - Settings → **Indexers** → add each Jackett indexer (Torznab URL + API key), or point them at
     Jackett's aggregate feed.
   - Settings → **Media Management** → **Root Folders**: add `/data/media/tv` (Sonarr) and
     `/data/media/movies` (Radarr).
   - Confirm a test grab imports by **hardlink** (same inode as the file in `/data/torrents`, no
     copy). If it copies, the `/data` layout is broken — recheck step 1.

### 7. Requests: Jellyseerr + Cantinarr
- **Jellyseerr** (`:5055`) → sign in with your Jellyfin account, connect it to Jellyfin, then add
  Sonarr (`sonarr:8989`) and Radarr (`radarr:7878`) with their API keys and the same root folders.
- **Cantinarr** (`:8585`) → run its setup wizard (admin account) and connect Jellyfin + the *arr
  services the same way. It overlaps Jellyseerr; use whichever front-end you prefer, or both.

### 8. Subtitles: Bazarr
**Bazarr** (`:6767`) → Settings → connect **Sonarr** (`sonarr:8989`) and **Radarr** (`radarr:7878`)
with their API keys (same host/path mapping — Bazarr sees the library at `/data/media/*` too). Then
Settings → **Languages** → add **Spanish** as a wanted language and enable subtitle providers
(OpenSubtitles, etc.). Bazarr drops `.srt` files next to each video, which Jellyfin shows alongside
the original audio — this is the reliable way to get "original version + Spanish subs" (far better
than trying to grab releases with embedded subs).

### 9. Jellyfin libraries
Jellyfin → Dashboard → Libraries → add a **Movies** library at `/data/media/movies` and a **Shows**
library at `/data/media/tv`. New imports from Sonarr/Radarr land there automatically. Set the
**metadata language** to Spanish if you want titles/overviews in Spanish (doesn't affect audio).

## Updating & operations
- **Update images:** `./run.sh playbooks/bootstrap-truenas.yml --tags media -e truenas_media_pull=true`
  (pulls, then `up -d` recreates only what changed).
- **Logs:** `ssh truenas 'docker logs <container>'` (e.g. `sonarr`, `qbittorrent`).
- **Re-run is idempotent:** datasets/subdirs/whitelist are only created/edited when missing, and
  homepage is only recreated when a key actually changed.

### Maximise Direct Play (server has no GPU)

Transcoding always happens **on the server**, and this one has no iGPU/QuickSync — so the goal is to
**avoid transcoding** and let each client Direct Play the original file (the client's own CPU/GPU
decodes it). You can't offload the *server's* transcode to clients; you sidestep it. Two levers:

**Client / playback side** (biggest impact):
- Use apps that Direct Play almost anything: **Jellyfin Media Player** (mpv), **Kodi + Jellyfin**,
  Android TV / Shield, Fire TV. Avoid the **web player** — it's the most transcode-happy.
- In each client set playback quality to **Original / Maximum** (a bitrate cap forces a transcode).
- Prefer **text subtitles (SRT/ASS)** over image-based (PGS/VOBSUB) — burned-in image subs force a
  transcode. Set subtitle mode/priority accordingly in Jellyfin.

**Acquisition side** — bias Sonarr/Radarr toward compatible releases with the ready-made custom
formats in **`media-custom-formats/`** (import + scoring instructions in that folder's README):
H.264 + AAC/AC3 score high (Direct Plays everywhere), DTS/TrueHD/Atmos score low (often transcoded),
HEVC optional depending on your clients. Given equal options they grab the file that plays without
transcoding. If a specific file still won't play on any client, pre-convert it once to H.264/AAC/SRT.

### Torrent VPN (gluetun + AirVPN)

qBittorrent runs **inside gluetun's network namespace** (`network_mode: service:gluetun`), so all
torrent traffic goes through the AirVPN WireGuard tunnel and gluetun's firewall **kill-switch** drops
everything if the VPN drops. Setup:

1. AirVPN → **Client Area → Config Generator → WireGuard**: pick a server/country, generate, and open
   the `.conf`. Copy into `hosts/truenas/media.env`:
   - `WIREGUARD_PRIVATE_KEY` ← `PrivateKey`
   - `WIREGUARD_PRESHARED_KEY` ← `PresharedKey` (AirVPN requires this)
   - `WIREGUARD_ADDRESSES` ← the `Address` line (e.g. `10.x.x.x/32`)
   - `VPN_SERVER_COUNTRIES` (e.g. `Netherlands`) or pin `VPN_SERVER_NAMES` to an AirVPN server name.
2. AirVPN → **Client Area → Ports**: reserve a port. Set `QBITTORRENT_BT_PORT` to it (and later set
   qBittorrent → Connection → *incoming connections port* to the same value). AirVPN port forwarding
   is **static** (reserved on the site) — gluetun does not negotiate it dynamically like PIA/Proton.
3. Deploy: `./run.sh playbooks/bootstrap-truenas.yml --tags media`.

**Verify the tunnel** (the IP seen by qBittorrent must be AirVPN's, not your home IP):
```bash
ssh truenas 'docker logs gluetun 2>&1 | grep -i "public ip"'          # gluetun reports the VPN IP
ssh truenas 'docker exec qbittorrent wget -qO- https://ipinfo.io/ip'  # should be the AirVPN exit IP
```
If gluetun is unhealthy, qBittorrent won't start (it `depends_on` gluetun `service_healthy`) — that's
the kill-switch working. To go back to no-VPN, revert the `gluetun`/`qbittorrent` block in the compose.

## Notes / caveats
- **Transcoding is CPU-only** — the Supermicro X10SRL-F (Xeon E5) has no iGPU/QuickSync. Prefer
  Direct Play (see above); the `/dev/dri` passthrough is left commented in the compose for a future GPU.
- **qBittorrent lives in gluetun's namespace** — its WebUI is published on host `8085`, but on the
  bridge the *arr apps must use **`gluetun:8080`**, not `qbittorrent:8080`.

## Observability of the media stack

The same exporter→Prometheus→alerts + Alloy→Loki + Grafana pattern the rest of the homelab uses,
layered onto the media stack. Everything runs **on the NAS** in the same compose and publishes its
port on `192.168.1.18`, so the hub's Prometheus scrapes it over the LAN (exactly like the
`graphite-exporter` at `:9108`). The hub-side pieces (jobs, alerts, dashboards) live under `core/`
and are picked up by `scripts/deploy.sh`.

```
sonarr/radarr/bazarr ─API─► exportarr ×3 ─┐
gluetun ─control:8000─► gluetun-exporter ─┤ scrape LAN
qbittorrent ─► qbittorrent-exporter ──────┼─► hub Prometheus ─► alerts (Discord) + Grafana "media"
jellyfin ─native /metrics ────────────────┘
ALL media containers ─► media-alloy (docker.sock) ─push─► hub Loki (job="media")
```

| Piece | Where | Port (`192.168.1.18`) | Prometheus job | Managed by |
|-------|-------|-----------------------|----------------|------------|
| exportarr (Sonarr) | NAS Docker | 9707 | `sonarr` | `media.compose.yml` |
| exportarr (Radarr) | NAS Docker | 9708 | `radarr` | `media.compose.yml` |
| exportarr (Bazarr) | NAS Docker | 9709 | `bazarr` | `media.compose.yml` |
| qbittorrent-exporter | NAS Docker | 9710 | `qbittorrent` | `media.compose.yml` |
| gluetun-exporter | NAS Docker | 9711 | `gluetun` | `media.compose.yml` |
| Jellyfin native `/metrics` | NAS Docker | 8096 | `jellyfin` | `media.compose.yml` |
| media-alloy (log shipper) | NAS Docker | — (pushes) | — (`job="media"` in Loki) | `alloy-media.config.alloy` |
| Prometheus jobs | Hub | — | — | `core/prometheus/prometheus.yml` |
| Alerts (group `media`) | Hub | — | — | `core/prometheus/rules/media-alerts.yml` |
| Dashboards (folder "media") | Hub | — | — | `core/grafana/dashboards/media/` |

**Keys are auto-provisioned.** exportarr no longer reads `config.xml`, so it needs each app's
`API_KEY`. The `truenas_media` role's existing key-discovery (the same one that fills the homepage
widgets) writes `SONARR_KEY`/`RADARR_KEY`/`BAZARR_KEY` into the NAS-side `.env` after first boot and
recreates the exporters — leave those blank in `media.env`. On a **fresh** install the three
exportarr containers restart-loop for a minute until the role writes the keys; that's expected.

**qBittorrent exporter needs no password.** The role widens qBittorrent's `AuthSubnetWhitelist` to
include the Docker bridge range (`truenas_media_bridge_subnet`, default `172.16.0.0/12`) alongside
the LAN, so the exporter — on the `media` bridge, talking to `gluetun:8080` — bypasses auth the same
way the homepage widget does.

**VPN health.** `gluetun-exporter` polls gluetun's control server (`:8000`, internal to the bridge).
Since gluetun ≥3.40 makes every control-server route private, `config/gluetun/auth-config.toml`
(bind-mounted) grants the exporter's read routes with `auth = "none"` — safe because `:8000` is never
published. The `VpnTunnelDown` alert (`gluetun_vpn_status == 0`) is the kill-switch canary; verify the
route list / metric names against your gluetun + exporter version after the first deploy.

**Jellyfin metrics — one manual fallback.** Jellyfin serves `/metrics` on `:8096` only when
`EnableMetrics` is on. The role flips it in Jellyfin's `system.xml` and restarts Jellyfin, but that
file only exists **after** the setup wizard. If the `jellyfin` target reads empty, enable it by hand:
Jellyfin **Dashboard → Advanced → Networking** (or edit `config/jellyfin/config/system.xml`:
`<EnableMetrics>true</EnableMetrics>`), then restart Jellyfin. Rich playback stats (active streams
per user) come from the **Playback Reporting** plugin, not the native endpoint.

**Toggle.** All of the above wiring is gated by `truenas_media_provision_metrics` (default `true`);
set it `false` to leave the exporters idle. The log shipper (`media-alloy`) always runs.

### Verify

```bash
ssh truenas 'docker compose -f /mnt/tank/mediaserver/docker-compose.yml ps'   # exporters Up
ssh truenas 'curl -s localhost:9707/metrics | head'                            # exportarr (…8-9)
ssh truenas 'curl -s localhost:8096/metrics | head'                            # Jellyfin native
```
Then, from the hub, `up{job=~"sonarr|radarr|bazarr|qbittorrent|gluetun|jellyfin"}` should be `1` in
Prometheus, and Grafana → folder **media** → **Overview** / **Logs** should have data.

## Notes

- The `graphite_exporter` expires a metric 5 min after its last push, so if netdata stops
  pushing, `/metrics` empties out — that's what `TrueNasNoData` watches (rather than only `up`,
  since the container itself stays reachable).
- `netdata.conf` tweaks shipped by the mapping repo are **not used**: they don't survive a
  TrueNAS OS update (immutable root fs), and the default netdata charts already cover what the
  dashboards need. Configure the export purely through the middleware (the Ansible role).
