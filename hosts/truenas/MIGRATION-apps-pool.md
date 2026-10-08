# Runbook — migrar las apps de `tank` → `apps` (SSD) con rollback

Procedimiento de producción para mover el **estado de las apps** (config + bases de datos + el motor
Docker) del pool SAS `tank` al SSD Intel `apps`, dejando en `tank` **solo el almacenamiento pesado**
(librería + descargas/torrents, ficheros externos de Nextcloud, backups del rpi5). Contexto y tabla
de reparto: ver [`README.md` → "Pool layout"](README.md#pool-layout-apps-ssd-vs-storage-tank).

> **Regla de oro:** NO destruyas nada de `tank/*` hasta que las apps estén verificadas funcionando en
> `apps`. Mientras `tank/*` siga existiendo, el rollback es trivial. Los snapshots `@migrate` que crea
> este runbook son tu punto de retorno limpio.

## Qué se mueve y qué se queda

| Se MIGRA a `apps` (SSD) | Se QUEDA en `tank` (almacenamiento) |
|---|---|
| `tank/mediaserver` → `apps/mediaserver` (config *arr/Jellyfin/qBittorrent) | `tank/media` (librería + **torrents/descargas**, hardlinks) |
| `tank/nextcloud` → `apps/nextcloud` (app + `./data` interno) | `tank/negri-data` (ficheros externos de Nextcloud) |
| `tank/nextcloud-db` → `apps/nextcloud-db` (Postgres) | `tank/backups` (repo restic del rpi5) |
| `tank/pi-infra-monitoring` → `apps/pi-infra-monitoring` (stack graphite) | `tank/scripts` (fan curve) |
| El motor Docker `ix-apps` (imágenes/overlay/logs) vía UI | |

---

## 0. Pre-flight (sin downtime)

En el NAS (`ssh truenas`, con sudo/root):

```bash
# El pool apps existe y tiene sitio para lo que vas a copiar.
zpool status apps
zfs list -o name,used tank/mediaserver tank/nextcloud tank/nextcloud-db tank/pi-infra-monitoring
zfs list -o name,avail apps

# Apunta el pool ACTUAL del motor Docker (lo necesitas para el rollback).
sudo midclt call docker.config | python3 -m json.tool   # fíjate en "pool" (debería decir "tank")

# ¿Tienes apps del CATÁLOGO de TrueNAS (no compose)? Míralo en la UI → Apps.
# Si las hay, el cambio de pool del motor (paso 4) también las migra/reinstala: tenlo en cuenta.
```

En el **hub** (donde corre Ansible), asegúrate de que los cambios del repo (el `nas.yml` que apunta a
`apps/*`, el rol `truenas_apps_snapshots`) están **commiteados, pusheados y pulleados**:

```bash
cd ~/pi-infra && git pull --ff-only && git log --oneline -1
```

> 💡 **De-risk opcional:** puedes hacer los pasos 1–3 + 5 primero **sin** tocar el motor Docker (paso 4),
> verificar que las apps funcionan ya con sus datos en `apps/*`, y mover el motor en una segunda ventana.
> Aísla el riesgo de la copia de datos del reinit del motor, a cambio de un segundo corte. Abajo va la
> versión combinada (un solo corte).

---

## 1. Parar los stacks (inicio del downtime)

Los compose siguen físicamente en `tank/*`, así que paras desde ahí. `down` apaga Postgres limpio:

```bash
sudo docker compose -f /mnt/tank/mediaserver/docker-compose.yml down
sudo docker compose -f /mnt/tank/nextcloud/docker-compose.yml down            # si tienes Nextcloud
sudo docker compose -f /mnt/tank/pi-infra-monitoring/docker-compose.yml down
sudo docker ps    # no deben quedar contenedores de estos stacks
```

## 2. Migrar los datos `tank` → `apps` (ZFS send | recv)

`zfs send | recv` copia bloques, permisos, ACLs y xattrs exactos. **No** usamos `-p`: así el dataset
destino hereda `mountpoint` de `apps` (→ `/mnt/apps/<ds>`) en vez de arrastrar el de tank.

```bash
for ds in mediaserver nextcloud nextcloud-db pi-infra-monitoring; do
  zfs list "tank/$ds" >/dev/null 2>&1 || { echo "skip tank/$ds (no existe)"; continue; }
  sudo zfs snapshot "tank/$ds@migrate"
  sudo zfs send "tank/$ds@migrate" | sudo zfs recv -F "apps/$ds"
done

# Verifica: los datasets están en apps y montados en /mnt/apps/<ds>.
zfs list -r apps
ls -la /mnt/apps/mediaserver/config         # debe tener la config real, no vacío
ls -la /mnt/apps/nextcloud-db               # datos de Postgres
```

Si algo de la copia falla aquí, **aún no has cambiado nada en caliente** — borra lo que se haya recibido
(`sudo zfs destroy -r apps/<ds>`) y reintenta. `tank/*` sigue intacto.

## 3. (Opcional, recomendado) Verificar las apps ya sobre `apps/*` antes de tocar el motor

Para aislar el riesgo, puedes desplegar ahora (motor Docker todavía en `tank`) y comprobar que las apps
leen bien sus datos migrados. Si prefieres el corte único, salta al paso 4 y despliega una sola vez en
el paso 5.

## 4. Cambiar el pool del motor Docker `tank` → `apps`

**UI:** *Apps → (Settings / Configuration) → "Choose Pool" → `apps`* y confirma. TrueNAS para el engine,
recrea `ix-apps` vacío en `apps` (las imágenes se vuelven a descargar) y deja los stacks compose caídos.

**CLI equivalente** (verifica el nombre del método en tu versión 25.10):

```bash
sudo midclt call -job docker.update '{"pool": "apps"}'
sudo midclt call docker.config | python3 -m json.tool   # "pool" ahora = "apps"
```

Tus bind-mounts (`apps/mediaserver`, …) **no se tocan** con esto; solo se mueve el almacén interno del
engine. Los docker-volumes con nombre (`media-alloy-data`, `nextcloud-alloy-data`) se pierden — son
caché de Alloy, inofensivo.

## 5. Re-desplegar desde el hub

Los roles encuentran los datasets `apps/*` ya presentes (no los recrean), sincronizan el compose y hacen
`up -d` (re-descarga de imágenes porque el engine está vacío):

```bash
cd ~/pi-infra/ansible
./run.sh playbooks/bootstrap-truenas.yml --tags docker          # monitoring  → apps/pi-infra-monitoring
./run.sh playbooks/bootstrap-truenas.yml --tags media           # media       → apps/mediaserver
./run.sh playbooks/bootstrap-truenas.yml --tags nextcloud       # nextcloud   → apps/nextcloud(+db)  [si lo usas]
./run.sh playbooks/bootstrap-truenas.yml --tags apps-snapshots  # snapshots ZFS recursivos sobre apps
```

## 6. Verificar (fin del downtime)

```bash
ssh truenas 'docker compose -f /mnt/apps/mediaserver/docker-compose.yml ps'    # todo Up
ssh truenas 'docker compose -f /mnt/apps/nextcloud/docker-compose.yml ps'      # si aplica
```

- Abre cada WebUI (`192.168.1.18:<port>`): Sonarr/Radarr con sus series/pelis e indexers; Jellyfin con
  sus bibliotecas; qBittorrent con sus torrents; **Nextcloud carga la sesión existente, NO la pantalla
  de instalación**.
- En el hub: `up{job=~"sonarr|radarr|bazarr|qbittorrent|gluetun|jellyfin|truenas"}` = 1 en Prometheus.
- Snapshots creados: *Data Protection → Periodic Snapshot Tasks* muestra las tareas `apps-auto-*`.
- Confirma que `tank` queda quieto en reposo: `zpool iostat tank 5` (sin apps escribiendo, casi 0 I/O).

## 7. Limpieza (SOLO cuando todo esté verificado)

```bash
# Borra los snapshots de migración y los datasets de app viejos en tank.
for ds in mediaserver nextcloud nextcloud-db pi-infra-monitoring; do
  sudo zfs destroy -r "tank/$ds" 2>/dev/null && echo "destruido tank/$ds"
done
# El ix-apps viejo del motor (si el engine estaba en tank) ya no se usa:
sudo zfs list -r tank | grep ix-apps        # confirma el nombre exacto
sudo zfs destroy -r tank/ix-apps            # solo si existe y confirmaste el cambio de motor
```

Se **conservan** `tank/media`, `tank/negri-data`, `tank/backups`, `tank/scripts`.

---

## Rollback — volver a `tank`

Funciona en cualquier momento **mientras no hayas hecho el paso 7** (los datos de `tank/*` siguen ahí,
congelados desde el paso 1). Pasos:

```bash
# 1. Parar los stacks que estén corriendo sobre apps.
sudo docker compose -f /mnt/apps/mediaserver/docker-compose.yml down
sudo docker compose -f /mnt/apps/nextcloud/docker-compose.yml down            # si aplica
sudo docker compose -f /mnt/apps/pi-infra-monitoring/docker-compose.yml down
```

```bash
# 2. Revertir el apuntamiento del repo (que vuelve a tank/*). En el HUB:
cd ~/pi-infra
git revert <sha-del-commit-de-migracion>     # o: git checkout <sha-previo> -- ansible/inventory/group_vars/nas.yml
git push && git pull --ff-only
```

```bash
# 3. Si cambiaste el motor Docker, devuélvelo a tank (UI o CLI):
sudo midclt call -job docker.update '{"pool": "tank"}'
```

```bash
# 4. Re-desplegar: las apps vuelven a arrancar leyendo tank/* (datos intactos desde el paso 1).
cd ~/pi-infra/ansible
./run.sh playbooks/bootstrap-truenas.yml --tags docker,media,nextcloud
```

Verifica igual que en el paso 6, pero contra `/mnt/tank/mediaserver/...`. Los datasets `apps/*` que se
crearon quedan huérfanos — bórralos cuando quieras: `sudo zfs destroy -r apps/<ds>`.

### Rollback si YA habías destruido `tank/*` (paso 7 hecho)

Entonces el origen bueno es `apps/*`. Invierte el send/recv antes de revertir el repo:

```bash
for ds in mediaserver nextcloud nextcloud-db pi-infra-monitoring; do
  zfs list "apps/$ds" >/dev/null 2>&1 || continue
  sudo zfs snapshot "apps/$ds@rollback"
  sudo zfs send "apps/$ds@rollback" | sudo zfs recv -F "tank/$ds"
done
```
…y luego los pasos 2–4 de arriba. (Por esto la regla de oro: no hagas el paso 7 hasta estar seguro.)

---

## Resumen del orden

```
0. pre-flight (apps existe, espacio, pool actual del motor, repo pulleado en el hub)
1. docker compose down   (tank paths)              ─┐ downtime
2. zfs send|recv  tank/* → apps/*  (+ @migrate)     │
3. (opcional) verificar apps sobre apps/*           │
4. UI: Apps → Choose Pool → apps                    │
5. ./run.sh ... --tags docker,media,nextcloud,apps-snapshots
6. verificar (UIs, Prometheus, zpool iostat tank)  ─┘
7. zfs destroy -r tank/<app datasets>   (SOLO tras verificar)

rollback (antes del 7): down apps → git revert nas.yml → motor a tank → redeploy tank
```
