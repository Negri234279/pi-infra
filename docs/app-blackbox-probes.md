# Añadir Blackbox probes a una app

Guía para dar a una app **probes de liveness** (HTTP/TCP/ICMP) reutilizando el
`blackbox-exporter` del core. No necesitas un exporter propio ni tocar el core.

## Cómo funciona (el modelo)

- El **`blackbox-exporter` del core** (rpi5) vive en la red `monitoring`, que todas
  las apps comparten. Cualquier `*-prometheus` de app lo alcanza por DNS:
  `blackbox-exporter:9115` — igual que ya reutilizan `postgres-exporter`.
- La Prometheus **de la app** carga jobs extra desde `scrape.d/` vía
  `scrape_config_files: /etc/prometheus/scrape.d/*.yml`.
- Por tanto, **cada app hace sus propios probes** soltando `scrape.d/probes.yml`.
  Los raspa **su** Prometheus, alertan por **su** Alertmanager y salen en **su**
  datasource de Grafana. Es "app-owned", coherente con el modelo per-app.

> Los probes de una app **no** aparecen en el dashboard `Pi · probes` del core (ese
> es solo para infra: hosts, red, Grafana/Loki). Cada app ve los suyos en su
> propio Grafana/datasource. Es intencional: mantiene el aislamiento per-app.

## Requisito (ya viene en `_template`)

El Prometheus de la app debe:
1. Estar en la red `monitoring` (para alcanzar `blackbox-exporter:9115`).
2. Cargar `scrape.d/`:
   - `prometheus.yml`: `scrape_config_files: [ /etc/prometheus/scrape.d/*.yml ]`
   - `compose.yml`: montar `./scrape.d:/etc/prometheus/scrape.d:ro`

`apps/_template/` ya trae los tres puntos. Las apps creadas antes de esto lo
activan añadiendo esas dos líneas (ver "App existente" abajo).

## Generar el archivo en una app

### App NUEVA (desde `_template`)
El template ya carga `scrape.d/` y trae `scrape.d/probes.yml.example`. Solo:
```bash
cd apps/<app>
cp scrape.d/probes.yml.example scrape.d/probes.yml
# edita los targets (URL/host) y el label name
```

### App EXISTENTE
1. Si su `prometheus.yml` aún no carga `scrape.d`, añádelo bajo `global:`:
   ```yaml
   scrape_config_files:
     - /etc/prometheus/scrape.d/*.yml
   ```
2. Si su `compose.yml` no monta el dir, añádelo al servicio `*-prometheus`:
   ```yaml
       volumes:
         - ./scrape.d:/etc/prometheus/scrape.d:ro
   ```
3. Crea `apps/<app>/scrape.d/probes.yml` (formato abajo).

## El archivo `probes.yml`

```yaml
# scrape_config_files espera un MAPPING con clave `scrape_configs`, NO una lista
# suelta (un `- job_name:` a pelo hace crash-loop a Prometheus).
scrape_configs:
  - job_name: blackbox-app-http
    metrics_path: /probe
    params:
      module: [http_2xx]          # módulo definido en core/blackbox/blackbox.yml
    static_configs:
      - targets: ["https://<app>.negri.es/health"]   # la URL a comprobar
        labels: { name: <app> }                       # nombre legible en alertas
    relabel_configs:
      # patrón estándar de Blackbox: el target real va como ?target=, y __address__
      # se reescribe al exporter compartido.
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "blackbox-exporter:9115"
```

**Qué es cada cosa:**
- `params.module`: el tipo de sonda. Disponibles hoy (en `core/blackbox/blackbox.yml`):
  `http_2xx` (HTTP, espera 2xx), `tcp_connect` (conexión TCP), `icmp` (ping).
  ¿Necesitas otro (p. ej. HTTP con status codes concretos, o mTLS)? Añade el
  módulo al `core/blackbox/blackbox.yml` (config compartida) y úsalo aquí.
- `targets`: la URL completa (con esquema) para HTTP, o `host:puerto` para TCP,
  o `host`/IP para ICMP.
- `labels.name`: aparece en las alertas y dashboards; ponle algo claro.
- El bloque `relabel_configs` es **idéntico siempre** — no lo cambies.

Para TCP en vez de HTTP: `module: [tcp_connect]` y `targets: ["<app>:<puerto>"]`.

## Alertar sobre los probes (opcional pero recomendado)

Añade una regla en las reglas de la app (`apps/<app>/observability/prometheus/rules/…`)
para que su Alertmanager avise:
```yaml
groups:
  - name: probes
    rules:
      - alert: AppProbeDown
        expr: probe_success == 0
        for: 3m
        labels: { severity: critical }
        annotations:
          summary: "Probe down: {{ $labels.name }}"
          description: "probe_success=0 >3m para {{ $labels.name }} ({{ $labels.instance }})."
```

## Desplegar y verificar

```bash
# en la rpi5, tras el sync/pull que trae el probes.yml:
docker compose restart <app>-prometheus          # recarga scrape.d
# o, si la app soporta reload en caliente:
docker compose exec -T <app>-prometheus wget -qO- --post-data='' http://localhost:9090/-/reload

# comprobar el probe (en el Prometheus de la app):
docker compose exec -T <app>-prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=probe_success' | grep -o '"name":"[^"]*"\|"value":\[[^]]*\]'
```
`probe_success = 1` = OK. Si da `0`, sonda directa al exporter para ver el motivo:
```bash
docker compose exec -T <app>-prometheus wget -qO- \
  'http://blackbox-exporter:9115/probe?module=http_2xx&target=https://<app>.negri.es/health' \
  | grep -E 'probe_success|probe_http_status_code'
```

## Checklist

- [ ] Prometheus de la app en red `monitoring` y con `scrape_config_files` cargando `scrape.d/`.
- [ ] `compose.yml` monta `./scrape.d:/etc/prometheus/scrape.d:ro`.
- [ ] `apps/<app>/scrape.d/probes.yml` con tus targets (mapping con `scrape_configs`).
- [ ] (opcional) regla `AppProbeDown` en las reglas de la app.
- [ ] Verificado `probe_success == 1`.
