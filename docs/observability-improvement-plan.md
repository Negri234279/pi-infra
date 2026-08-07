# Plan de mejora de observabilidad — pi-infra

> Estado: **en progreso** (rama `observability-improvements`).
> Origen: incidente del **2026-08-06**, la rpi5 (`192.168.1.7`) se congeló ~4h
> estando ociosa (kernel vivo respondiendo ICMP, userspace muerto). Firma
> compatible con un **dropout del NVMe por gestión de energía (APST) en reposo**.
>
> **Progreso (2026-08-06):**
> - ✅ **Fase 1** — journald + logs de contenedores → Loki (Alloy). Requirió subir
>   los límites de ingesta de Loki para el backfill inicial.
> - ✅ **Fase 2** — smartctl-exporter (imagen arm64 propia, sin manifest upstream) +
>   grupo de alertas `storage`.
> - ✅ **Fase 4** — alertas Loki de kernel/NVMe (`HostKernelErrors`,
>   `HostFilesystemReadOnly`), verificadas end-to-end.
> - ✅ **Dead-man** activado (healthchecks.io + `HEARTBEAT_URL`).
> - ✅ **Dashboard "Pi · logs"** en Grafana (host journald + contenedores).
> - ✅ **Fase 7** — rpi3 (192.168.1.6) onboarded metrics-only vía `hosts/rpi3/` +
>   `deploy-host.sh`; `up{job="node-rpi3"}==1`, grupo de alertas `host-rpi3`.
> - ✅ **Fase 5** — Blackbox exporter: TCP:22 a rpi5/rpi3 (liveness real) + ICMP a
>   router (192.168.1.2)/switch (192.168.1.5); alerta `ProbeDown`. Pendiente
>   manual: cambiar el check de Uptime Kuma de ICMP a TCP:22.
> - ✅ **healthchecks.io → Grafana** (dashboard "Pi · heartbeats", vía Bearer).
> - ✅ **watcher rpi3→rpi5** (sidecar `rpi5-watcher` + healthchecks).
> - ✅ **Fase 6** — pi-overview enriquecido (uptime/boot, swap, disco I/O, temps
>   SoC/NVMe, fila SMART) + node-exporter `--collector.systemd`.
> - ✅ **Fase 3** — throttle/undervoltage: `scripts/rpi-throttled.sh` + timer systemd →
>   textfile collector; métricas `node_rpi_*` + alertas `HostUnderVoltage`/`HostThrottled`.
> - ✅ Selector `$host` (rpi5/rpi3) en pi-overview.
> - ⬜ Pendiente: **merge a `main`** (+ instalar el timer de throttle en la Pi).
> - 🔀 **Pendiente de merge**: la rama `observability-improvements` a `main` (la Pi
>   está desplegando desde esa rama vía deploy.sh).

Este documento recoge, para cada mejora: la **decisión** (opción elegida,
alternativas descartadas y por qué), los **pasos de implementación**, los
**ficheros tocados**, la **verificación** y el **rollback**.

---

## 0. Contexto y qué ya está hecho

### 0.1 Endurecimiento ya aplicado en la Pi (no versionado — es config del SO)
| Medida | Detalle | Estado |
|---|---|---|
| NVMe APST off | `nvme_core.default_ps_max_latency_us=0` en `/boot/firmware/cmdline.txt` | ✅ activo |
| Watchdog HW | `RuntimeWatchdogSec=15` (efectivo 60s por drop-in de RPi OS); `bcm2835_wdt` | ✅ activo |
| Journal persistente | drop-in `/etc/systemd/journald.conf.d/99-persistent.conf` (`Storage=persistent`) que gana al `40-rpi-volatile-storage.conf` de fábrica | ✅ escribiendo en `/var/log/journal` |

### 0.2 Ya versionado, pendiente de activar
- **Dead-man's switch** (commit de esta tanda): grupo `deadman` en
  `core/prometheus/rules/alerts.yml` (`Watchdog` = `vector(1)`, `NodeExporterAbsent`),
  ruta + receiver `heartbeat` en `core/alertmanager/alertmanager.yml`, secret
  `HEARTBEAT_URL` en `core/docker-compose.yml` + `.env.example`.
  **Falta**: crear el check en healthchecks.io y poner `HEARTBEAT_URL` en `.env`.

### 0.3 Estado actual del stack (lo que ya existe)
- **Métricas**: Prometheus (`core/`) + node-exporter + cadvisor + exporters
  (postgres, cloudflare, npm, mktxp, snmp). Alertas en `core/prometheus/rules/`.
- **Logs**: Loki + Alloy **con ruler funcionando**, pero Alloy **solo ingiere el
  syslog remoto del router** (`core/alloy/config.alloy`). **No** recoge journald
  del host ni logs de contenedores.
- **Dashboards**: `pi-overview.json` (resumen) + `node-exporter-full.json` (importado).
- **Blackbox / uptime externo**: fuera del repo (Uptime Kuma con un ping ICMP a
  la rpi5 que **no** detectó la caída).

### 0.4 Principios de decisión
1. **Nativo de Prometheus/Loki** antes que herramienta aparte → alertas unificadas
   por Alertmanager → Discord, y config versionada en git.
2. **Aditivo y con bajo blast-radius**: cada fase es un contenedor/scrape/regla
   nuevos; rollback = revertir el commit.
3. **Atacar primero la clase de fallo del incidente** (NVMe + visibilidad de logs
   del host) antes que mejoras cosméticas.
4. **Detectar un freeze del host requiere un vigía externo** (nada que corra en la
   rpi5 sobrevive a su propio cuelgue).

---

## Secuencia recomendada y dependencias

```
Fase 1 (logs host→Loki) ─┬─► Fase 4 (alerta Loki de kernel/NVMe)
                         │
Fase 2 (smartctl NVMe) ──┴─► (alertas SMART incluidas en la fase 2)
Fase 0.2 (activar dead-man)  ─► independiente, hazlo cuanto antes
Fase 3 (throttle textfile)   ─► independiente, baja prioridad
Fase 5 (Blackbox + Kuma)     ─► independiente
Fase 6 (node-exporter + dash)─► independiente
Fase 7 (rpi3)                ─► reutiliza fases 1/5
```

**Orden sugerido**: 0.2 → 1 → 2 → 4 → 5 → 6 → 3 → 7.

---

## Fase 1 — Logs del host y de contenedores → Loki

### Decisión
- **Elegido**: ampliar el **Alloy que ya tienes** con `loki.source.journal` (host)
  y `loki.source.docker` (contenedores).
- **Descartado**:
  - *Promtail* — deprecado a favor de Alloy; ya tienes Alloy.
  - *Docker logging driver `loki`* — requiere plugin en el daemon, más frágil en
    ARM y no cubre el journald del host.
- **Por qué ahora**: acabas de activar journald persistente; sin esta fase los
  logs del cuelgue siguen solo accesibles por SSH y se pierden fuera del journal.

### Pasos
1. **Montar el journal y el socket en Alloy** (`core/docker-compose.yml`, servicio `alloy`):
   ```yaml
       volumes:
         - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
         - alloy-data:/var/lib/alloy/data
         - /var/log/journal:/var/log/journal:ro     # journal persistente
         - /run/log/journal:/run/log/journal:ro      # journal en RAM (boot actual)
         - /etc/machine-id:/etc/machine-id:ro
         - /var/run/docker.sock:/var/run/docker.sock:ro
   ```
   Nota: Alloy necesita permiso de lectura sobre el journal (grupo
   `systemd-journal`). Si no lee, añadir al servicio `user: root` **o**
   `group_add: [<gid de systemd-journal>]`. Se valida en el paso de verificación.

2. **Añadir las fuentes a `core/alloy/config.alloy`** (sin tocar el bloque de syslog):
   ```alloy
   // ── Host journald ──────────────────────────────────────────────
   loki.source.journal "host" {
     path          = "/var/log/journal"
     max_age       = "24h"
     labels        = { job = "systemd-journal", host = "rpi5" }
     relabel_rules = loki.relabel.journal.rules
     forward_to    = [loki.write.default.receiver]
   }
   loki.relabel "journal" {
     forward_to = []                    // solo se usa por su .rules
     rule { source_labels = ["__journal__systemd_unit"], target_label = "unit" }
     rule { source_labels = ["__journal_priority_keyword"], target_label = "severity" }
   }

   // ── Logs de contenedores ───────────────────────────────────────
   discovery.docker "containers" { host = "unix:///var/run/docker.sock" }
   loki.source.docker "containers" {
     host          = "unix:///var/run/docker.sock"
     targets       = discovery.docker.containers.targets
     labels        = { job = "docker", host = "rpi5" }
     relabel_rules = loki.relabel.docker.rules
     forward_to    = [loki.write.default.receiver]
   }
   loki.relabel "docker" {
     forward_to = []
     rule {
       source_labels = ["__meta_docker_container_name"]
       regex         = "/(.*)"
       target_label  = "container"
     }
   }
   ```

3. **Desplegar**: `docker compose -f core/docker-compose.yml up -d alloy`.

### Ficheros tocados
- `core/docker-compose.yml` (volúmenes de `alloy`)
- `core/alloy/config.alloy`
- Actualizar el comentario de cabecera de `config.alloy` (ya no es "solo router").

### Verificación
- Alloy arriba sin errores: `docker logs alloy | tail`.
- En Grafana → Explore (Loki): `{job="systemd-journal", host="rpi5"}` y
  `{job="docker"}` devuelven líneas recientes.
- Etiquetas acotadas (no cardinalidad explosiva): revisar que `unit`/`container`
  no generen miles de series.

### Rollback
Revertir el commit y `docker compose up -d alloy`. Loki conserva lo ya ingerido;
no hay migración destructiva.

### Riesgos
- Permisos de lectura del journal (mitigado con `group_add`/`user`).
- Cardinalidad si se promueven labels con alta variabilidad → mantener solo
  `unit`, `severity`, `container`, `host`.

---

## Fase 2 — Salud SMART del NVMe (`smartctl_exporter`) + alertas

### Decisión
- **Elegido**: `prometheuscommunity/smartctl-exporter` como contenedor con acceso
  a `/dev/nvme0`.
- **Descartado**:
  - *Solo hwmon de node-exporter* — únicamente da temperatura, no salud SMART.
  - *Cron con `smartctl` + textfile collector* — funciona pero reinventa el
    exporter y es más frágil; el exporter ya expone métricas normalizadas.
- **Por qué**: el incidente es NVMe. SMART anticipa degradación (spare, warning,
  errores de medio, unsafe shutdowns) que la temperatura no ve.

### Pasos
1. **Servicio** (`core/docker-compose.yml`):
   ```yaml
     smartctl-exporter:
       image: prometheuscommunity/smartctl-exporter:v0.13.0
       container_name: smartctl-exporter
       restart: unless-stopped
       user: root
       privileged: true          # acceso SMART al NVMe (alternativa: cap_add SYS_RAWIO+SYS_ADMIN + devices)
       command:
         - "--smartctl.device-include=/dev/nvme0"
       networks: [monitoring]
   ```
2. **Scrape job** (`core/prometheus/prometheus.yml`):
   ```yaml
     - job_name: smartctl
       static_configs:
         - targets: ["smartctl-exporter:9633"]
   ```
3. **Alertas** — nuevo grupo `storage` en `core/prometheus/rules/alerts.yml`
   (⚠️ **confirmar nombres exactos de métrica en el primer scrape**, varían por
   versión; ajustar tras ver `/metrics`):
   ```yaml
     - name: storage
       rules:
         - alert: NvmeCriticalWarning
           expr: smartctl_device_critical_warning > 0
           for: 1m
           labels: { severity: critical }
           annotations:
             summary: "NVMe critical warning"
             description: "El NVMe reporta critical_warning != 0 — riesgo de fallo."
         - alert: NvmeSpareLow
           expr: smartctl_device_available_spare_ratio * 100 < 20
           for: 10m
           labels: { severity: warning }
           annotations:
             summary: "NVMe spare bajo"
             description: "Available spare por debajo del 20%."
         - alert: NvmeMediaErrors
           expr: increase(smartctl_device_media_errors_total[1h]) > 0
           for: 0m
           labels: { severity: warning }
           annotations:
             summary: "Errores de medio en el NVMe"
             description: "El NVMe acumuló errores de medio en la última hora."
   ```
4. **Desplegar** + recargar Prometheus (`curl -X POST localhost:9090/-/reload`).

### Ficheros tocados
- `core/docker-compose.yml`, `core/prometheus/prometheus.yml`,
  `core/prometheus/rules/alerts.yml`.

### Verificación
- `docker exec smartctl-exporter wget -qO- localhost:9633/metrics | grep smartctl_` →
  anotar nombres reales y ajustar las expr.
- En Prometheus, target `smartctl` UP; en Grafana, panel de salud NVMe (fase 6).

### Rollback
Quitar servicio + job + grupo, revertir. Sin estado persistente.

### Riesgos
- `privileged`: aceptable en un host doméstico single-tenant; alternativa menos
  amplia con `cap_add: [SYS_RAWIO, SYS_ADMIN]` + `devices: ["/dev/nvme0"]`.

---

## Fase 3 — Métrica de undervoltage/throttle (textfile collector)

### Decisión
- **Elegido**: `--collector.textfile` en node-exporter + timer systemd en el host
  que vuelca `vcgencmd get_throttled`.
- **Descartado**: `rpi_exporter` dedicado — un binario más que mantener para una
  sola métrica; el textfile es trivial y ya tienes node-exporter.
- **Por qué**: node-exporter **no** expone el bitmask de throttling de la Pi (punto
  ciego conocido). En el incidente salió `0x0`, pero es una lectura en vivo que no
  queda grabada; con esto tendrías la serie histórica.
- **Prioridad**: baja (nice-to-have).

### Pasos
1. **node-exporter** (`core/docker-compose.yml`): añadir flag y montar un dir:
   ```yaml
       command:
         - "--path.rootfs=/host"
         - "--path.procfs=/host/proc"
         - "--path.sysfs=/host/sys"
         - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
         - "--collector.textfile.directory=/host/var/lib/node_exporter/textfile"
       volumes:
         - /:/host:ro,rslave
         - /var/lib/node_exporter/textfile:/host/var/lib/node_exporter/textfile:ro
   ```
2. **Script en el host** `/usr/local/bin/rpi-throttled.sh`:
   ```sh
   #!/bin/sh
   d=/var/lib/node_exporter/textfile; f="$d/rpi_throttled.prom"
   v=$(vcgencmd get_throttled | sed 's/throttled=//')          # p.ej. 0x0
   printf 'node_rpi_throttled %d\n' "$v" > "$f.$$" && mv "$f.$$" "$f"
   ```
3. **Timer systemd** cada 60s (unit + timer) que ejecute el script.
4. **Alerta** (opcional): `node_rpi_throttled != 0` → warning (bit 0 = undervolt
   ahora, bit 16 = undervolt ocurrido).

### Verificación
- `cat /var/lib/node_exporter/textfile/rpi_throttled.prom`.
- En Prometheus: `node_rpi_throttled`.

### Rollback
Quitar flag/volumen/timer.

---

## Fase 4 — Alerta de Loki sobre errores de kernel/NVMe

### Decisión
- **Elegido**: regla LogQL en el ruler de Loki (que ya empuja a Alertmanager),
  nuevo fichero `core/loki/rules/fake/host-log-alerts.yml`.
- **Depende de la Fase 1** (necesita el journald en Loki).

### Pasos
1. Crear `core/loki/rules/fake/host-log-alerts.yml`:
   ```yaml
   groups:
     - name: host-logs
       rules:
         - alert: HostKernelErrors
           expr: |
             sum(count_over_time({job="systemd-journal", host="rpi5"}
               |~ `(?i)(nvme.*(timeout|reset|i/?o error)|pcie link down|hung task|blocked for more than [0-9]+ seconds|out of memory|oom-kill|kernel panic|BUG:)` [5m])) > 0
           for: 0m
           labels: { severity: critical }
           annotations:
             summary: "Errores de kernel/NVMe en el host"
             description: "{{ $value }} línea(s) críticas en el journal en 5m. Revisar Grafana → Logs del host."
   ```
2. Recargar el ruler de Loki (reinicio del contenedor `loki` o `POST /loki/api/v1/rules` según versión).

### Verificación
- `docker exec loki wget -qO- localhost:3100/ruler/ring` (ruler activo) y que la
  regla aparezca; probar con una línea inyectada (`logger "BUG: test"` en el host).

### Rollback
Borrar el fichero de regla y recargar.

---

## Fase 5 — Blackbox Exporter (y decisión sobre Uptime Kuma)

### Decisión
- **Elegido**: `prom/blackbox-exporter` en la rpi5 sondeando **por TCP:22 / HTTP**
  (no ICMP) a rpi3, router, switch y servicios; alertas por Alertmanager.
- **Clave del incidente**: el ICMP no detectó la caída porque **el kernel sigue
  respondiendo ping** en un freeze de userspace. Cambiar de herramienta con la
  misma sonda ICMP **no** lo arregla. La sonda debe ser de **userspace** (TCP:22
  o HTTP), que sí habría fallado.
- **Límite**: Blackbox en la rpi5 **no** puede detectar el freeze de la propia
  rpi5 (muere con ella) → eso lo cubre el **dead-man externo** (Fase 0.2).
- **Uptime Kuma**:
  - *Descartado como fuente de verdad interna* (sistema aparte, notif. aparte).
  - *Mantener solo como vigía externo* (fuera de la LAN) para tener un punto de
    vista independiente, y **cambiar el check de la rpi5 de ICMP a TCP:22**.

### Pasos
1. **Servicio** (`core/docker-compose.yml`):
   ```yaml
     blackbox-exporter:
       image: prom/blackbox-exporter:v0.25.0
       container_name: blackbox-exporter
       restart: unless-stopped
       volumes:
         - ./blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro
       networks: [monitoring]
   ```
2. **`core/blackbox/blackbox.yml`** con módulos `icmp`, `tcp_connect`, `http_2xx`.
3. **Scrape job multi-target** (`core/prometheus/prometheus.yml`), patrón estándar:
   ```yaml
     - job_name: blackbox-tcp
       metrics_path: /probe
       params: { module: [tcp_connect] }
       static_configs:
         - targets:
             - 192.168.1.x:22      # rpi3 SSH (liveness REAL)
             - 192.168.1.7:22      # rpi5 SSH (útil desde otro vigía, no para su propio freeze)
       relabel_configs:
         - source_labels: [__address__]
           target_label: __param_target
         - source_labels: [__param_target]
           target_label: instance
         - target_label: __address__
           replacement: blackbox-exporter:9115
   ```
4. **Alertas** (`core/prometheus/rules/alerts.yml`, grupo nuevo `probes`):
   ```yaml
     - alert: ProbeDown
       expr: probe_success == 0
       for: 3m
       labels: { severity: critical }
       annotations:
         summary: "Sonda fallando: {{ $labels.instance }}"
         description: "probe_success=0 >3m para {{ $labels.instance }}."
   ```

### Verificación
- Target `blackbox-tcp` UP; `probe_success{instance="192.168.1.x:22"} == 1`.
- Prueba: apagar SSH de la rpi3 → la alerta salta (a diferencia del ICMP).

### Rollback
Quitar servicio + job + grupo.

---

## Fase 6 — node-exporter (collector systemd) y dashboard

### Decisión
- **Elegido**: activar `--collector.systemd` (estado de servicios) y **enriquecer
  `pi-overview.json`** con paneles que en el incidente habrían sido clave.
- **Descartado**: rehacer el dashboard desde cero — ya tienes `node-exporter-full`
  para el detalle; `pi-overview` es el resumen y solo necesita añadidos.

### Pasos
1. **node-exporter systemd collector** (`core/docker-compose.yml`) — requiere dbus:
   ```yaml
       command:
         - ...
         - "--collector.systemd"
       volumes:
         - /:/host:ro,rslave
         - /run/systemd:/run/systemd:ro
         - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket:ro
   ```
   (Marcar como **opcional/medio riesgo**: si complica el arranque en ARM, se
   revierte; el valor es ver servicios caídos.)
2. **Paneles nuevos en `pi-overview.json`**:
   - **Uptime / último boot** (`node_boot_time_seconds`, o
     `time() - node_boot_time_seconds`) — un hueco/reinicio se ve de un vistazo.
   - **Swap usado**.
   - **Disco I/O**: `rate(node_disk_io_time_seconds_total[5m])` (utilización) y
     latencia media.
   - **Temp NVMe** separada de la del SoC (`node_hwmon_temp_celsius` por `chip`).
   - **Errores de red** (`node_network_*_errs_total`).
   - Fila **SMART del NVMe** (tras Fase 2).

### Verificación
- `node_systemd_unit_state` presente; paneles renderizan con datos.

### Rollback
Revertir el JSON (Grafana recarga por provisioning) y quitar el flag.

---

## Fase 7 — Onboarding de la rpi3 (✅ scaffold hecho)

### Decisión (revisada por RAM)
- **IaC multi-host, un solo repo**: carpeta **`hosts/rpi3/`** con su propio
  compose, desplegada **solo en la rpi3** vía `scripts/deploy-host.sh rpi3`
  (proyecto compose `rpi3`). El `docker-compose.yml` raíz de la rpi5 **no**
  incluye `hosts/`, así que el hub nunca levanta estos servicios.
- **Metrics-only**: la rpi3 tiene ~0.89 GB RAM libres con sus apps, así que corre
  **solo node-exporter** (~20 MB). **Sin Alloy/logs** (≈150 MB sería demasiado).
- **Blackbox vive en la rpi5**, no en la rpi3 (sondea hacia fuera) — Fase 5.
- **Job separado `node-rpi3`** (no targets extra bajo `node`) para no alterar el
  dashboard single-host `pi-overview` ni las alertas de la rpi5; la rpi3 tiene su
  propio grupo de alertas `host-rpi3`.

### Implementado
- `hosts/rpi3/docker-compose.yml` — node-exporter, publica `:9100` en la LAN.
- `hosts/rpi3/README.md` — despliegue + logs opcionales (vía ligera).
- `scripts/deploy-host.sh` — deploy genérico por host (git-pull aware, `-p <host>`).
- `core/prometheus/prometheus.yml` — job `node-rpi3` → `192.168.1.6:9100` (`host=rpi3`).
- `core/prometheus/rules/alerts.yml` — grupo `host-rpi3` (Down/HighMemory/HighCpu/DiskLow).

### Pendiente (fuera de este scaffold)
- **Blackbox TCP:22 rpi5→rpi3**: se añade en la **Fase 5** (target `192.168.1.6:22`).
- **Logs de la rpi3** (opcional, si sobra RAM): remote-syslog nativo al `:514` del
  Alloy de la rpi5 (ligero, recomendado) o un Alloy propio (pesado). Ver README.

### Verificación
- En la rpi3: `./scripts/deploy-host.sh rpi3`, luego desde la rpi5
  `up{job="node-rpi3"}` == 1. Métricas visibles en `node-exporter-full` filtrando
  por `instance="192.168.1.6:9100"`.

### Rollback
Quitar job/labels/sonda; parar el node-exporter de la rpi3.

---

## Registro de decisiones (resumen)

| Tema | Elegido | Descartado | Motivo |
|---|---|---|---|
| Logs del host | Alloy `journal`+`docker` | Promtail / driver Loki | Ya tienes Alloy; Promtail deprecado |
| Salud NVMe | smartctl_exporter | solo hwmon / cron+textfile | SMART real, métricas normalizadas |
| Throttle Pi | textfile + vcgencmd | rpi_exporter | Una sola métrica, sin binario extra |
| Alertas de log | Loki ruler → Alertmanager | herramienta aparte | Reutiliza pipeline existente |
| Liveness | Blackbox **TCP:22/HTTP** | ICMP (Kuma o Blackbox) | ICMP da verde falso en freeze |
| Freeze del propio host | Dead-man externo (healthchecks.io) | cualquier sonda local | Nada local sobrevive al cuelgue |
| Uptime Kuma | Solo vigía externo | Fuente de verdad interna | Sistema/notif. aparte |

---

## Preguntas abiertas (para ti)

1. **Heartbeat externo**: ¿healthchecks.io (SaaS gratis) o algo self-hosted fuera
   de la rpi5? (Self-hosted en la LAN no vale: si cae la luz/red, cae con ella.)
2. **IPs de rpi3 y rpi5** para los targets de Blackbox (ya tengo `192.168.1.7`).
3. **`privileged` en smartctl_exporter**: ¿ok, o prefieres la variante con
   `cap_add` acotado?
4. **rpi3**: ¿qué corre exactamente? (define si necesita dead-man propio o basta
   con la sonda).
5. ¿Implemento en **una rama por fase** o una rama única `observability-improvements`
   con commits separados?
```
