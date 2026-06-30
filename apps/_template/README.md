# App template

Copy this folder to `apps/<app>/` and wire it into the central stack.

## Steps

1. **Copy & rename**

   ```bash
   cp -r apps/_template apps/myapp
   # replace every "myapp" with your app name in compose.yml and prometheus/prometheus.yml
   ```

2. **Register it in the root orchestrator** — add one line under `include:` in the
   repo-root `docker-compose.yml`:

   ```yaml
   include:
     - core/docker-compose.yml
     - apps/myapp/compose.yml
   ```

3. **Add a Grafana datasource** — copy the per-app template block in
   `core/grafana/provisioning/datasources/datasources.yml` and change
   `name` / `uid` / `url` to match your Prometheus service name
   (`http://myapp-prometheus:9090`).

4. **Database** (shared Postgres — don't run your own):

   ```bash
   cp apps/myapp/postgres/provision.env.example apps/myapp/postgres/provision.env
   # set APP_DB / APP_DB_USER / APP_DB_PASSWORD
   ```

   The core provisioner creates that role+db on `up`. Join the external `db`
   network and connect at `pgbouncer:6432/<APP_DB>` (runtime) — migrations go
   directly to `postgres:5432/<APP_DB>` (the pooler is transaction-mode; a
   migrator's session advisory lock needs a direct connection).

5. **Bring it up** (from the repo root):

   ```bash
   docker compose up -d
   ```

   Grafana restarts to pick up the new datasource; your app's Prometheus appears as a
   datasource named after your app.

## Notes

- The app's own Prometheus scrapes business metrics on the **private** `myapp-net`.
  It joins `monitoring` only so Grafana can reach it by DNS — don't put app scrape
  jobs in the infra Prometheus.
- Expose the app to the LAN/internet through **nginx-proxy-manager** (core, `:81`
  admin UI) rather than publishing host ports here.
- App-specific Grafana dashboards: drop JSONs under
  `core/grafana/dashboards/<app>/` (the provider shows each subdir as a folder) and
  bind their datasource to your app's central uid (e.g. `prometheus-myapp`).
