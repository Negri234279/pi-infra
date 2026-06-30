# apps/

Each app that runs on the Pi gets its own subfolder here with a self-contained
`compose.yml` (plus any config it needs). The root `docker-compose.yml` `include:`s
each app, so `docker compose up -d` from the repo root brings the **core infra + all
apps** up together.

```
apps/
├─ _template/      ← copy this to start a new app
│  ├─ compose.yml
│  ├─ prometheus/prometheus.yml
│  └─ README.md
└─ <yourapp>/
```

## Convention

- **One folder per app.** Self-contained `compose.yml` that joins the shared external
  `monitoring` network.
- **Each app owns its Prometheus** (stable service name `<app>-prometheus`) on a
  private network, joined to `monitoring` so the central Grafana queries it as a
  datasource. The infra Prometheus does **not** scrape app business metrics — cadvisor
  already covers per-container resource usage.
- **Register the app** by adding one line to the root `docker-compose.yml` `include:`
  list and a datasource block in
  `core/grafana/provisioning/datasources/datasources.yml`.

See [`_template/README.md`](_template/README.md) for the full step-by-step.

> Apps can also live in their own repos and join the same `monitoring` network — the
> `include:` route here is just for apps you want vendored and orchestrated alongside
> the core.
