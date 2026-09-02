# Observability stack (Grafana · Prometheus · Alloy · Tempo · Loki · Alertmanager)

Single-source configs shared **unchanged** by `infra/dev`, `infra/staging` and
`infra/prod` — every service name is unified to `coreforge-*`, so the same URLs
resolve in all three environments. Per-env differences live in each env's
`scrape.d/` (where the app runs) and compose file (which ports are published).

```
app  ──OTLP http/protobuf──►  Tempo (traces) ── span-metrics ──► Prometheus
app  ──stdout JSON─► docker ─► Alloy ──────────────────────────► Loki (logs)
app  ◄─/metrics (prom-client) ◄────────────────────────────────  Prometheus
browser (Faro) ──/collect+CORS─► Alloy ──► traces→Tempo · vitals/events/errors→Loki
Prometheus ──/probe──► Blackbox ──HTTP──► app /api/healthz · Loki/Tempo /ready
Prometheus ──rules──► Alertmanager ──► Discord (webhook via env, not in git)
```

Grafana is **not** part of the prod stack: prod joins the external `monitoring`
network on the Pi and the central pi-infra Grafana queries this stack through
the `*-coreforge` datasources (provisioned from `grafana/provisioning/`, synced
by the `sync-pi-infra` workflow). dev/staging run their own local Grafana with
the exact same provisioning.

## UIs / ports

| Env     | Grafana                  | Prometheus         | OTLP (Alloy)      | Faro RUM (Alloy)   |
| ------- | ------------------------ | ------------------ | ----------------- | ------------------ |
| dev     | `127.0.0.1:13000`        | `127.0.0.1:19090`  | `127.0.0.1:4318`  | `127.0.0.1:12347`  |
| staging | `:13001` (LAN, for NPM)  | loopback           | `:4320` (LAN)     | `:12347` (LAN)     |
| prod    | central pi-infra Grafana | `monitoring` (DNS) | via NPM → `:4318` | via NPM → `:12347` |

(Grafana's native 3000–3200 range is WinNAT-reserved on Windows 11, hence the
13xxx remaps in dev/staging.)

Dev also exposes the blackbox exporter at `127.0.0.1:19115` for debugging
(`/probe?target=…&module=http_2xx`); staging/prod keep it internal-only.

## How the correlation works

- The OTel Node SDK (`otel/instrumentation.mjs`, preloaded via `--import`)
  auto-instruments http / fetch / better-sqlite3 and exports **traces only** to
  Tempo.
- `src/lib/logger.ts` writes one JSON line per record to stdout **including the
  active span's `trace_id`/`span_id`**; Alloy tails the container and pushes to
  Loki. The Loki datasource's derived field turns `trace_id` into a **View
  trace** link (Tempo), and Tempo's `tracesToLogsV2` links back.
- Tempo's `metrics_generator` remote-writes RED span-metrics + service graph
  into Prometheus (`traces_spanmetrics_*`), with exemplars linking back to
  traces.

## App metrics (`/metrics`, prom-client)

Served by `src/pages/metrics.ts`, guarded in `src/middleware.ts` so it is only
reachable from inside the docker network / localhost — never through the proxy.

- `http_request_duration_seconds{method,route,status}` — inbound HTTP, labelled
  by Astro route pattern (bounded cardinality)
- `coreforge_events_total{type}` — business events, same taxonomy as `logEvent`
- `coreforge_events_persist_failures_total` — logEvent → SQLite write failures
- `coreforge_users_total`, `coreforge_filters_total`, `coreforge_categories_total`,
  `coreforge_orgs_total` — live gauges read from SQLite on scrape
- `coreforge_build_info{version,service,environment}` — constant 1, release pin
- plus default Node.js process metrics (`process_*`, `nodejs_*`)

## Liveness probes (blackbox)

`coreforge-blackbox` (prom/blackbox-exporter) is driven by Prometheus to probe
HTTP endpoints and record `probe_success` / `probe_duration_seconds` per target.
Modules live in `blackbox/blackbox.yml` (`http_2xx`, `tcp_connect`; no `icmp`, so
no NET_RAW needed). Targets split by where the address is env-specific:

- **App** (`job=blackbox-app`, `name=app`) — probes the real `/api/healthz`
  request path. Defined in each env's `scrape.d/` because the app address
  differs (dev `host.docker.internal:4300`, staging/prod `coreforge-app:4321`).
  Stronger than `up{job="coreforge-app"}`: `up` only means `/metrics` scraped,
  the probe means the HTTP handler actually answered 2xx.
- **Obs readiness** (`job=blackbox-http`, `name=loki|tempo`) — probes
  `/ready` on Loki and Tempo (service names unified, so this lives in the shared
  `prometheus.yml`). `/ready` returns 503 while a component is replaying even
  though its `/metrics` is already scrapeable.

Prometheus also scrapes the exporter's own `/metrics` (`job=coreforge-blackbox`)
for self-health. Grafana surfaces all of it in the **Liveness · probes** row of
`coreforge-overview` (current state / up-down history / probe latency /
availability over range). Alerts: `CoreforgeProbeDown` (probe_success == 0, 2m,
critical) and `CoreforgeProbeSlow` (probe_duration_seconds > 2s, 10m, warning).

## Alerting

Prometheus rules in `prometheus/rules/coreforge-alerts.yml` → coreforge's own
Alertmanager → Discord. The webhook comes from `COREFORGE_DISCORD_WEBHOOK_URL`
in the env file on the host; an init container writes it to a secret file that
`alertmanager.yml` references (`webhook_url_file`), so the secret never lands
in git. Unset in dev = alerts only visible in Prometheus/Grafana.

## Browser RUM (Grafana Faro)

`src/otel-web/init.ts` boots `@grafana/faro-web-sdk` (+ `-tracing`) and POSTs
Faro payloads to Alloy's `faro.receiver` on `:12347/collect` — CORS-gated with
a strict origin allowlist (`*.negri.es` + localhost dev). The receiver fans
out: traces → Tempo; logs / events / measurements / exceptions → Loki as
logfmt lines with labels `job=faro` and `kind=log|event|measurement|exception`
(the per-env app name travels in the body as `app_name=`). Out of the box this
captures Web Vitals (LCP/CLS/INP/FCP/TTFB), unhandled errors, console
warnings/errors, sessions and page views; custom business events go through
`trackEvent` (`src/otel-web/track.ts`) or `window.__cfTrack`. Configure via
`FARO_COLLECTOR_URL` / `FARO_APP_NAME` on the app container (unset = RUM off).

NPM wiring: keep `otlp.coreforge-conveyor-filters.negri.es` → `coreforge-alloy:4318`
(server-side OTLP path unused by browsers today, dev app still uses it) and add a
**custom location** `/collect` → `coreforge-alloy:12347` (prod, over `monitoring`)
or `192.168.1.11:12347` (staging) so the Faro SDK reaches the receiver through
the same TLS host.

Useful LogQL:

- Web vitals p75: `quantile_over_time(0.75, {job="faro", kind="measurement"} | logfmt type, value_lcp | type="web-vitals" | unwrap value_lcp | __error__="" [$__auto]) by ()`
- Events: `sum by (event_name) (count_over_time({job="faro", kind="event"} | logfmt event_name [$__auto]))`
- Frontend errors: `{job="faro", kind="exception"}`
- One session's story: `{job="faro"} |= "session_id=<id>"`
