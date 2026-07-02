# powerlog — Pi/prod stack (`apps/powerlog/` in pi-infra)

Self-contained powerlog deployment for the shared Raspberry Pi managed by
[**pi-infra**](https://github.com/Negri234279/pi-infra). This folder is the
**source of truth** in the powerlog repo; CI syncs it into
`pi-infra/apps/powerlog/`, where the pi-infra root `docker-compose.yml`
`include:`s it.

## What runs here

App + its own observability + its own alerting, all prefixed `powerlog-` and
joined to the external `monitoring` network so the **central Grafana** (pi-infra
core) can query this stack as the `*-powerlog` datasources:

| Service                      | Role                                              |
| ---------------------------- | ------------------------------------------------- |
| `powerlog-api` / `powerlog-web` | the app (images `negrii/powerlog-*:latest`)    |
| `powerlog-prometheus`        | scrapes app + obs; `external_labels: app=powerlog` |
| `powerlog-loki`              | logs (Alloy ships only `powerlog-*` containers)   |
| `powerlog-tempo`             | traces (OTLP from the API) + span-metrics         |
| `powerlog-alloy`             | Docker log shipper → `powerlog-loki`              |
| `powerlog-alertmanager` (+init) | alerts → powerlog's **own** Discord channel    |

There is **no Grafana here** — the pi-infra core owns the single shared Grafana.
Its datasources (`prometheus-powerlog` / `loki-powerlog` / `tempo-powerlog`) and
the powerlog dashboards live in pi-infra (`core/grafana/`).

**No Postgres here either** — the database is the **shared core Postgres**
(pi-infra `core/postgres`). powerlog gets its own role + database via
`postgres/provision.env`, which the core provisioner materializes. The app's
runtime connects through **PgBouncer** (`pgbouncer:6432`, transaction pooling)
and **migrations connect directly** to Postgres (`postgres:5432`,
`MIGRATIONS_DATABASE_URL`) because the migrator holds a session-level advisory
lock the pooler can't carry. Postgres metrics/alerts/dashboard live in the core
(datname `powerlog`).

## Observability naming

Everything carries a `powerlog` prefix so it coexists in the shared Grafana:
datasource uids `*-powerlog`, dashboard uids/titles `powerlog *`, Prometheus
`external_labels: app=powerlog` + `powerlog-*` job names, and every alert label
`app: powerlog`. The canonical Grafana provisioning lives in the powerlog repo
under `infra/observability/` (used by the dev stack) and is mirrored into
pi-infra for the shared Grafana.

## Alerting

Independent from the pi-infra core. powerlog's Prometheus evaluates
`prometheus/rules/powerlog-alerts.yml` and pushes firing alerts to
`powerlog-alertmanager`, which notifies powerlog's **own** Discord webhook
(`POWERLOG_DISCORD_WEBHOOK_URL`) — a different channel from the core's host/infra
alerts. Core resource alerts (CPU/RAM/disk/temp) stay in pi-infra core.

## Config

Two gitignored files (copy each `.example`):

```bash
cp powerlog.env.example powerlog.env                   # app secrets / keys / webhook
cp postgres/provision.env.example postgres/provision.env   # DB name / user / password
```

- `postgres/provision.env` declares the DB/user/password the **core provisioner**
  creates on the shared Postgres.
- `powerlog.env` is the app's `env_file`; its `DATABASE_URL` (→ `pgbouncer:6432`)
  and `MIGRATIONS_DATABASE_URL` (→ `postgres:5432`) must use the **same password**
  as `provision.env` (single source of truth).

## Run

In production it comes up as part of the pi-infra root `docker compose up -d`
(which also brings up the shared Postgres/PgBouncer this app depends on). The app
has **no `depends_on`** for the DB (it lives in the core, a separate compose
file): the entrypoint migrates then starts, and the restart policy retries until
the shared DB + provisioner are ready.

Standalone (`docker compose -f apps/powerlog/compose.yml up`) only brings up
powerlog's own services; it still needs the external `monitoring` + `db` networks
and the core Postgres reachable on `db` to be fully functional.

## Sync to pi-infra (automated)

This folder is **not** copied by hand. The `sync-pi-infra` GitHub Action
(`.github/workflows/sync-pi-infra.yml`) runs on every push to `main` that touches
`infra/**` and opens a PR in the pi-infra repo. The contract (also in
`scripts/sync-pi-infra.sh`, runnable locally for a dry run):

| Source (powerlog) | Destination (pi-infra) |
| --- | --- |
| `infra/prod/` | `apps/powerlog/prod/` |
| `infra/observability/` (minus `grafana/`) | `apps/powerlog/observability/` |
| `infra/observability/grafana/dashboards/{powerlog-overview,cloudflare-r2}.json` | `core/grafana/dashboards/powerlog/` |
| `infra/observability/grafana/provisioning/datasources/datasources.yaml` | `core/grafana/provisioning/datasources/powerlog.yml` |

`prod/compose.yml` mounts `../observability`, so the stack and the obs configs are
synced side-by-side under `apps/powerlog/` to keep that path valid.

Real `*.env` secrets are never synced (only `*.env.example`). One-time pi-infra
setup: the root `docker-compose.yml` must `include: - apps/powerlog/prod/compose.yml`,
and this repo needs a secret **`PI_INFRA_SYNC_TOKEN`** (PAT/App token with
`contents:write` + `pull-requests:write` on pi-infra) and, if the repo isn't
`Negri234279/pi-infra`, a variable **`PI_INFRA_REPO`**.

Test the contract locally without CI:

```bash
scripts/sync-pi-infra.sh /path/to/local/pi-infra
```
