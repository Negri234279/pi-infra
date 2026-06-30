# NGINX Proxy Manager (core)

NPM is a **first-class core service** (see `core/docker-compose.yml`): the Pi's
reverse proxy on `:80`/`:443` with the admin UI on `:81`. It uses the embedded
SQLite DB, so no separate database is needed.

NPM exposes no Prometheus metrics natively. We tail its access log with
[prometheus-nginxlog-exporter] (`npm-exporter` service) and turn it into
`nginx_http_*` metrics (requests by status/uri/method, response-time histogram,
sizes, parse errors). Dashboard: grafana.com **25257** ("Nginx Log Exporter
Dashboard"), provisioned under the **Infra** folder. Metrics live in the infra
Prometheus (job `nginx-proxy-manager`).

## Files

| File | Mounted in NPM at | Purpose |
| --- | --- | --- |
| `npm-custom/http_top.conf`    | `/data/nginx/custom/http_top.conf`    | defines `log_format nginxlog` |
| `npm-custom/server_proxy.conf`| `/data/nginx/custom/server_proxy.conf`| adds a combined `access_log` to every proxy host → `/data/logs/all_proxy_access.log` |
| `exporter-config.yml`         | (mounted in `npm-exporter`)           | parses that combined log into metrics |
| `data/`, `letsencrypt/`       | `/data`, `/etc/letsencrypt`           | NPM runtime data + certs (gitignored, created by NPM) |

The custom confs are mounted read-only into NPM by the compose, so they take effect
on first start — no manual copy needed. NPM's own per-host logs keep working
alongside the combined log.

## Critical invariant

The `format` in `exporter-config.yml` and `log_format nginxlog` in
`http_top.conf` **must be byte-for-byte identical**. If they drift,
`nginx_parse_errors_total` climbs and panels go empty — that metric is on the
dashboard precisely to catch this.

## Verify

```bash
curl -s http://<pi>:4040/metrics | grep -E '^nginx_(http_response_count_total|parse_errors_total)'
# parse_errors_total should stay 0.
```

In Prometheus (`http://<pi>:9090/targets`) the `nginx-proxy-manager` job should be
UP. In the dashboard, pick `job = nginx-proxy-manager` from the dropdown.

## Migrating an existing NPM

If you already run NPM in another stack, before first `up` here: stop the old NPM,
copy its `data/` and `letsencrypt/` dirs into `core/nginx-proxy-manager/`, and make
sure ports `80`/`443`/`81` are free on the host.

[prometheus-nginxlog-exporter]: https://github.com/martin-helmich/prometheus-nginxlog-exporter
