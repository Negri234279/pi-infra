# observability-platform

Full self-hosted infrastructure stack for a **Raspberry Pi 5 (Linux ARM64)**, split
into a **core** (reverse proxy + observability) and an **apps** area where each app
drops its own Docker config. One `docker compose up -d` from the repo root brings up
everything via Compose `include:`.

```
RPi5 ── Docker
│
├─ ROOT docker-compose.yml  (include: core + each app → one project)
│
├─ network "monitoring" (shared, external)
│   ├─ nginx-proxy-manager . :80/:443  (proxy)  + :81 (admin UI)
│   ├─ npm-exporter ........ NPM access-log → metrics
│   ├─ grafana ............. :3000  → datasources: Infra + one per app
│   ├─ prometheus-infra .... :9090  → scrapes node-exporter + cadvisor + npm-exporter
│   ├─ node-exporter ....... host: CPU / RAM / swap / disk / net / temp
│   ├─ cadvisor ............ every container on the Pi
│   ├─ alertmanager ........ :9093  → routes alerts → Discord
│   └─ <app>-prometheus .... lives under apps/<app>/, joins this network
│
└─ network "<app>-net" (private: app ↔ db ↔ its own Prometheus)
```

## Layout

```
docker-compose.yml          # ROOT orchestrator — `include:` core + each app
.env.example
core/
  docker-compose.yml        # nginx-proxy-manager(+exporter), grafana, prometheus-infra,
                            #   node-exporter, cadvisor, alertmanager(+init)
  nginx-proxy-manager/      # NPM custom log config + exporter config + runtime data
  prometheus/               # infra scrape jobs + rule_files + alerting
  alertmanager/             # routing + Discord receiver (webhook_url_file)
  grafana/                  # provisioning (datasources/dashboards) + dashboard JSONs
apps/
  README.md                 # convention for adding an app
  _template/                # copy this to apps/<app>/ to onboard a new app
scripts/
  create-network.sh         # create shared `monitoring` network (idempotent)
  fetch-dashboards.sh       # download community dashboards → core/grafana/dashboards
  deploy.sh                 # pull + apply repo changes (idempotent)
  systemd/                  # timer that runs deploy.sh on the Pi
```

## Quick start

```bash
cp .env.example .env            # set GF_ADMIN_PASSWORD + DISCORD_WEBHOOK_URL
./scripts/create-network.sh     # create the shared `monitoring` network (once)
docker compose up -d            # core + all registered apps
# ./scripts/fetch-dashboards.sh # optional: refresh the community dashboards
```

The Pi is at **192.168.1.7** on the LAN. Internal wiring (datasources, scrape
targets) uses Docker service DNS, so it never needs the IP — only access from other
machines does.

| Service          | URL                            | Notes                            |
| ---------------- | ------------------------------ | -------------------------------- |
| NPM admin UI     | http://192.168.1.7:81          | `admin@example.com` / `changeme` (forced change on first login) |
| NPM proxy        | http://192.168.1.7 / https     | :80 / :443                       |
| Grafana          | http://192.168.1.7:3000        | admin / `GF_ADMIN_PASSWORD`      |
| Prometheus infra | http://192.168.1.7:9090        | host + container + NPM metrics   |
| Alertmanager     | http://192.168.1.7:9093        | routes alerts → Discord          |
| node-exporter    | (internal `node-exporter:9100`)| host metrics                     |
| cadvisor         | (internal `cadvisor:8080`)     | per-container metrics            |
| npm-exporter     | (internal `npm-exporter:4040`) | NPM request metrics              |

Grafana ships pre-provisioned: the **Infra** datasource (default), an **Alertmanager**
datasource, a **powerlog** datasource template, plus the **Node Exporter Full**,
**Cadvisor**, **NPM** and **Pi · overview** dashboards.

> Run only the core (no apps): `docker compose -f core/docker-compose.yml up -d`.

### Configuration (`.env`)

All settings live in a single **`.env` at the repo root** (`cp .env.example .env`):
`GF_ADMIN_USER` / `GF_ADMIN_PASSWORD`, `PROM_RETENTION_TIME` / `PROM_RETENTION_SIZE`,
and `DISCORD_WEBHOOK_URL`. Variables are interpolated into both the core services and
the apps.

Keep this file at the **root**, not in `core/`. Because the root
`docker-compose.yml` uses `include:`, an included file (`core/docker-compose.yml`)
falls back to a local `core/.env` only when no root `.env` defines the variable — the
**root `.env` always wins** in the normal `docker compose up -d` workflow. A stray
`core/.env` would then be silently ignored. (`core/.env` only takes over if you run
the core in isolation with `-f core/docker-compose.yml`, where `core/` becomes the
project directory.) Both paths are git-ignored, so secrets never get committed.

### Keeping the Pi in sync with the repo

[`scripts/deploy.sh`](scripts/deploy.sh) pulls the latest commit and applies it:
it recreates only the services whose definition changed and hot-reloads/restarts the
ones whose mounted config changed (so a one-line edit never bounces the whole stack).
Run it by hand, or install the systemd timer in
[`scripts/systemd/`](scripts/systemd/README.md) to poll every few minutes — pull-based,
no inbound ports.

## Adding an app

Each app lives in `apps/<app>/` with its own `compose.yml` and owns its Prometheus.
Copy the template and wire it in:

1. `cp -r apps/_template apps/myapp` and replace `myapp` throughout.
2. Add one line under `include:` in the root `docker-compose.yml`:
   `- apps/myapp/compose.yml`.
3. Add a datasource block in
   `core/grafana/provisioning/datasources/datasources.yml` (copy the per-app
   template, change `name`/`uid`/`url`).
4. **Database**: `cp apps/myapp/postgres/provision.env.example apps/myapp/postgres/provision.env`
   and set `APP_DB` / `APP_DB_USER` / `APP_DB_PASSWORD`. The core provisioner
   creates that role+db on the **shared Postgres** on `up`; the app connects via
   `pgbouncer:6432` (runtime) and `postgres:5432` (migrations). Join the `db`
   network. No per-app Postgres.
5. `docker compose up -d`.

The infra Prometheus does **not** scrape app business metrics — keep app scrape jobs
in the app's own Prometheus. cadvisor already covers each app container's resource
usage globally. Full step-by-step in [`apps/_template/README.md`](apps/_template/README.md).

Apps can also live in their own repos and just join the `monitoring` network — the
`include:` route is for apps you want vendored and orchestrated alongside the core.

### App dashboards

Drop an app's Grafana JSONs under `core/grafana/dashboards/<app>/` and bind their
datasource to the app's central uid (e.g. `prometheus → prometheus-myapp`). The
dashboards provider (`foldersFromFilesStructure: true`) shows each app's JSONs in a
Grafana folder named after the subdirectory. Logs/traces panels (Loki/Tempo) won't
resolve here — the central Grafana is metrics-only; use the app's own Grafana for
full correlation.

## Shared database (Postgres + PgBouncer)

One Postgres for every app (`core/postgres`), on the private `db` network, never
published to the host. Apps don't run their own Postgres — they get an isolated
**role + database** on this instance:

- **Provisioning** (`core/postgres/provision/provision.sh`): an idempotent
  one-shot that runs on every `up`. It reads each `apps/<app>/postgres/provision.env`
  (`APP_DB` / `APP_DB_USER` / `APP_DB_PASSWORD`, operator-set) and ensures the
  role, database and grants (`REVOKE CONNECT … FROM PUBLIC`, so apps can't reach
  each other's data). New apps need no manual SQL.
- **PgBouncer** (transaction pooling) fronts Postgres. A wildcard `[databases]`
  plus `auth_query` means a freshly-provisioned app works through the pooler with
  **zero PgBouncer config** — it asks Postgres for the password via a SECURITY
  DEFINER function. Apps point their runtime at `pgbouncer:6432`.
- **Migrations bypass the pooler**: a session-level advisory lock is incompatible
  with transaction pooling, so migration runners connect to `postgres:5432`
  directly (a separate `*_MIGRATIONS_*` URL).
- **Metrics**: one `postgres-exporter` auto-discovers every database; the infra
  Prometheus scrapes it and the **PostgreSQL · shared** dashboard (Databases
  folder) filters by `datname`. DB alerts (down, connection pressure) live in the
  core and route to the core's Discord.

Set `POSTGRES_SUPERUSER_PASSWORD`, `PG_EXPORTER_PASSWORD` and
`PGBOUNCER_AUTH_PASSWORD` in the root `.env`.

## Reverse proxy (NGINX Proxy Manager)

NPM is a core service (no longer an external integration): the Pi's reverse proxy on
`:80`/`:443`, admin UI on `:81`, embedded SQLite (no separate DB). Its access log is
turned into Prometheus metrics by `npm-exporter`. Config and the critical log-format
invariant are documented in
[`core/nginx-proxy-manager/README.md`](core/nginx-proxy-manager/README.md).

**Migrating an existing NPM:** stop your old NPM, copy its `data/` and `letsencrypt/`
into `core/nginx-proxy-manager/`, and free ports `80`/`443`/`81` before `up`.

## Alerting

Prometheus evaluates the rules in `core/prometheus/rules/` and pushes firing alerts
to **Alertmanager**, which notifies a **Discord** channel.

- Set `DISCORD_WEBHOOK_URL` in `.env` (Discord → Server Settings → Integrations →
  Webhooks → New Webhook → Copy URL).
- On `up`, the `alertmanager-init` container writes that URL into a secret file that
  Alertmanager reads via `webhook_url_file` — the secret never touches the config or
  git. (Alertmanager can't expand env vars itself, hence the init step.)
- Rules cover the Pi core: node-exporter down, high CPU / memory / swap, SoC
  temperature (warn 75 °C / critical 82 °C), disk space (warn 85% / critical 95% /
  predicted-full-in-24h), and target/cadvisor down. Critical alerts re-notify hourly;
  a critical inhibits its matching warning.

Test the path end to end:

```bash
# Fire a dummy alert straight into Alertmanager (should hit Discord):
curl -XPOST http://192.168.1.7:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {"labels":{"alertname":"PingTest","severity":"warning","instance":"rpi5"},
   "annotations":{"summary":"manual test","description":"if you see this, Discord works"}}]'
```

Edit thresholds in `core/prometheus/rules/alerts.yml`, then reload Prometheus
(`curl -XPOST http://192.168.1.7:9090/-/reload`).

## Notes

- Images are multi-arch; the compose runs **on the Pi**, so arm64 is pulled
  automatically.
- Prometheus retention is bounded (`PROM_RETENTION_TIME` / `PROM_RETENTION_SIZE`) to
  protect the Pi's disk from cAdvisor's high series count.
- `monitoring` is kept external on purpose: it lets both `include:`d apps and apps in
  separate repos attach to the same network.
- RPi throttling/undervoltage flags (`vcgencmd get_throttled`) aren't exposed by
  node-exporter; add a small textfile-collector or rpi exporter later if needed.
