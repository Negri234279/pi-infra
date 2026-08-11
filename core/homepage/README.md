# homepage — portal único del stack

`ghcr.io/gethomepage/homepage` sirve un panel con TODOS los servicios de la Pi:
enlace + estado + widget (cuando existe) para el **core**, y una sección **Apps** que
se rellena **sola**. Definido en `core/docker-compose.yml` (servicio `homepage`), en la
red `monitoring` y con el socket Docker montado en `:ro`.

- UI: `http://192.168.1.7:3001` (o `https://home.negri.es` vía NPM).
- Config: `core/homepage/config/` (bind-mount a `/app/config`).

## Cómo funciona

- **Core** → se declara a mano en `config/services.yaml`, agrupado en Observabilidad /
  Red & Proxy / Datos.
- **Apps** → NO se tocan aquí. Cada app se auto-registra con **docker labels**
  `homepage.*` en su propio `compose.yml`; homepage las lee por el socket y las coloca
  bajo el grupo `Apps`. El deploy que ya existe (`scripts/deploy.sh`) las trae — sin
  action ni fichero extra.

### Regla de URLs

| Campo | Valor | Por qué |
|---|---|---|
| `href` | subdominio público `https://<svc>.negri.es` (por NPM) | es el enlace que abre el usuario |
| `siteMonitor` / `widget.url` | URL INTERNA del contenedor (`http://grafana:3000`) | homepage está en `monitoring`; evita TLS/proxy y bucles de auth |

Credenciales de widgets → variables `{{HOMEPAGE_VAR_*}}` inyectadas por el compose desde
`.env`. Si la variable está vacía el widget no puebla, pero la tarjeta sigue con
`href` + `siteMonitor`.

## Contrato de auto-registro de una app (docker labels)

En el `compose.yml` de la app (en SU repo), sobre el servicio principal:

```yaml
services:
  proxy-control:
    # ...
    labels:
      - homepage.group=Apps                       # grupo (usa "Apps")
      - homepage.name=Proxy Control               # nombre visible
      - homepage.icon=nginx.png                   # Dashboard Icons / mdi-… / si-…
      - homepage.href=https://proxy.negri.es      # enlace público (NPM)
      - homepage.description=Gestión de proxy hosts
      # Widget OPCIONAL (interno). Ej. healthcheck propio con customapi:
      - homepage.widget.type=customapi
      - homepage.widget.url=http://proxy-control:4321/health
      # Estado del contenedor en la tarjeta (opcional):
      - homepage.docker.container=proxy-control
```

Requisitos para que la app aparezca:
1. El contenedor corre en la Pi (lo trae el deploy/sync habitual).
2. Para que el `widget.url` interno sea alcanzable, el contenedor debe estar en la red
   `monitoring` (todas las apps del stack ya lo están).
3. `homepage.group=Apps` para que caiga en la sección Apps del layout.

> Multi-widget: usa `homepage.widgets[0].type=…`, `homepage.widgets[1].type=…`.
> Docs completas: https://gethomepage.dev/configs/docker/

### Apps sincronizadas desde su propio repo

`apps/proxy-control/` y `apps/powerlog/prod/` son copias **aterrizadas por sync** (su
fuente de verdad está en el repo de la app). Editar sus `compose.yml` aquí lo pisaría el
próximo sync, así que las labels deben añadirse **en el repo de origen** y llegar por el
sync habitual. Snippets listos:

```yaml
# proxy-control (repo propio) — servicio proxy-control
labels:
  - homepage.group=Apps
  - homepage.name=Proxy Control
  - homepage.icon=nginx.png
  - homepage.href=https://proxy.negri.es
  - homepage.description=Gestión de proxy hosts
  - homepage.docker.container=proxy-control
  - homepage.widget.type=customapi
  - homepage.widget.url=http://proxy-control:4321/health
```

```yaml
# powerlog (repo propio) — servicio powerlog-web
labels:
  - homepage.group=Apps
  - homepage.name=Powerlog
  - homepage.icon=mdi-flash
  - homepage.href=https://powerlog.negri.es
  - homepage.description=Consumo eléctrico
  - homepage.docker.container=powerlog-web
```

`apps/wake-lan-app/` sí es local y ya trae sus labels de ejemplo.

## Añadir un servicio del core

Edita `config/services.yaml` (grupo correspondiente) siguiendo la regla de URLs de
arriba. Widgets nativos disponibles en este stack: `grafana`, `prometheus`, `npm`,
`wgeasy`; para el resto usa `siteMonitor` o `customapi`.

## Prerequisitos manuales (fuera de git)

- **NPM**: crea un proxy host `home.negri.es` → `homepage:3000` (puerto del contenedor).
  Crea también los subdominios que quieras publicar (grafana, prom, npm, wg, …).
- **DNS**: un registro por subdominio usado.
- **Seguridad**: las UIs de administración (NPM `:81`, wg-easy, Prometheus,
  Alertmanager) NO deben quedar expuestas en internet. Protégelas con una **Access
  List** de NPM (LAN/VPN) o publícalas solo por IP de LAN. homepage sí puede ser
  público: sus widgets usan la red interna, no los subdominios.

## Hardening opcional del socket

Hoy homepage monta `/var/run/docker.sock:ro` y corre como root (necesario para leer el
socket, como documenta homepage). Alternativa de menor privilegio: interponer
`ghcr.io/tecnativa/docker-socket-proxy` (solo `CONTAINERS=1`) y apuntar `docker.yaml` a
`host: dockerproxy, port: 2375`.

## Recarga

homepage vigila `config/` en caliente. `scripts/deploy.sh` además hace
`docker compose restart homepage` cuando cambia algo bajo `core/homepage/` (determinista).
