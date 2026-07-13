# Observability stack (dev)

Always-on in the dev compose override. Metrics, logs and traces, correlated by
`trace_id` in Grafana.

```
API ──OTLP──► Tempo (traces)        ┐
API ─stdout─► Alloy ──► Loki (logs) ├─► Grafana
API ─/metrics◄─ Prometheus (metrics)┘
```

## Run

```bash
docker compose -f infra/docker-compose.dev.yml \
  --env-file infra/env/dev.env.example up --build
```

## UIs

Host ports for Grafana/Loki/Tempo are remapped into the 13xxx range because the
3000–3200 range is unbindable on Windows 11 (WinNAT-reserved). Container ports
are unchanged, so inter-service config (datasources, Alloy push, OTLP) is too.

| Service    | URL                    | Notes                      |
| ---------- | ---------------------- | -------------------------- |
| Grafana    | http://localhost:13000 | anonymous admin (dev only) |
| Prometheus | http://localhost:9090  | scrapes the API `/metrics` |
| Tempo      | http://localhost:13200 | OTLP in on 4318/4317       |
| Loki       | http://localhost:13100 | fed by Alloy               |
| Alloy      | http://localhost:12345 | tails Docker stdout        |

Grafana ships pre-provisioned datasources (Prometheus/Loki/Tempo) and these
dashboards (drop a JSON in `grafana/dashboards/` to add one):

| Dashboard                       | What it answers                                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **powerlog · API overview**     | HTTP/GraphQL, CQRS, errors, DB, runtime, logs, auth, R2, email.                                                                |
| **powerlog · Coaching**         | The invitation funnel (incl. invites that turn into signups), churn by actor, current links/backlog, what coaches actually do. |
| **powerlog · Redis & realtime** | Redis health/memory/throughput (via `redis_exporter`) + the SSE streams and events that ride on it.                            |
| **powerlog · PostgreSQL**       | Server-side DB metrics (postgres_exporter, dev only — prod's DB is the shared core one).                                       |
| **powerlog · Cloudflare R2**    | Avatar object storage.                                                                                                         |
| **powerlog · Web RUM (Faro)**   | Browser-side sessions, web vitals, JS errors.                                                                                  |

Exporters: `powerlog-postgres-exporter` (dev only) and `powerlog-redis-exporter`
(**dev and prod** — powerlog owns its Redis, whereas prod's Postgres belongs to
the shared core stack). The Redis job lives in the shared `prometheus.yml`; the
Postgres one is dropped into the per-env `scrape.d/`.

## How the correlation works

- **nestjs-cls** assigns a `correlationId` per request (`x-correlation-id`
  header or generated). The guard adds `userId`.
- **OpenTelemetry** (`src/tracing.ts`) auto-instruments http/graphql/pg and adds
  CQRS command/query spans; its pino instrumentation injects `trace_id`/`span_id`.
- Every Pino log line therefore carries `correlationId`, `userId`, `trace_id`.
- In Grafana (Loki datasource derived fields, see `provisioning/datasources`):
    - a Loki log → **View trace** (`trace_id`) → Tempo;
    - a Loki log → **Related logs** (`correlationId`) → all logs of the same flow;
    - a Tempo span → **Logs for this span** (`tracesToLogsV2`) → Loki.

> **Logs + host-run API:** Alloy tails **Docker container** stdout. If you run the
> API on the host (`pnpm dev`), its logs never reach Loki, so the Logs panels and
> the `trace_id`/`correlationId` links will be empty for the API. To get them,
> run the dockerized `api` service (it logs JSON in compose) or add a Pino→Loki
> transport for host runs. Metrics and traces work regardless (scrape /
> `localhost:4318`).

## Custom metrics (`/metrics`)

- `http_request_duration_seconds{kind,operation,status}` — inbound HTTP + GraphQL
- `cqrs_command_duration_seconds{command,status}`
- `cqrs_query_duration_seconds{query,status}`
- `cqrs_events_total{event}` — domain/integration events (mostly auth flows)
- `domain_errors_total{code,kind}`
- `powerlog_emails_sent_total{type,status}`
- `powerlog_avatars_processed_total{source,status}`
- `powerlog_notifications_created_total{type}`
- `powerlog_build_info{version,service,environment}` (constant 1 — release pin)
- **Coaching** (→ _powerlog · Coaching_):
    - `powerlog_coach_invitations_total{status,invitee}` — the funnel. `invitee` is
      `existing` (the invitee already had an account) or `new` (the email had none),
      so accepted+new is the sign-up auto-link — which runs in an event handler and
      is therefore invisible to the per-command CQRS counters. What those already
      cover (rate/failures of every coaching command) is deliberately not repeated.
    - `powerlog_coach_links_removed_total{by}` — churn, by who ended it.
    - `powerlog_coaching_{links,coaches,athletes,pending_invitations}` — current
      state, sampled at scrape time from the read model the admin dashboard uses.
- **Redis / realtime** (→ _powerlog · Redis & realtime_):
    - `powerlog_redis_up` — 0 also means "not configured" (Redis is optional).
    - `powerlog_realtime_connections` — open SSE streams (≈ tabs with the app open).
    - `powerlog_realtime_events_total{type}` — counts recipients, not publishes.
- plus default Node.js process metrics (`process_*`, `nodejs_*`).

The API-wide ones are visualised in the **powerlog · API overview** dashboard
(Overview · HTTP & GraphQL · CQRS · Errors · Business · Runtime · Logs).

## Disabling tracing

Set `OTEL_SDK_DISABLED=true` (or leave `OTEL_EXPORTER_OTLP_ENDPOINT` unset
outside compose).
