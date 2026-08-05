# Network gear observability — MikroTik RB750Gr3 + CSS326-24G-2S+RM

Metrics, logs and alerts for the two MikroTik boxes on the LAN. Everything runs
in the **core** stack and surfaces in the shared Grafana / Alertmanager (→ Discord).

| Device | IP | Metrics | Logs | Alerts |
|--------|-----|---------|------|--------|
| RB750Gr3 router (RouterOS 7.23.2) | `192.168.1.2` | `mktxp` (RouterOS API) | remote syslog → Alloy → Loki | metrics + **log** |
| CSS326 switch (SwOS 2.18) | `192.168.1.5` | `snmp-exporter` (SNMP v2c, IF-MIB) | **none** — SwOS has no logging | metrics only |

> **SwOS limitation (not a config gap):** SwOS 2.18 has no local log, no remote
> syslog and no SNMP traps. The switch is therefore metrics-only. If you need
> switch logs, the CSS326 can dual-boot **RouterOS** (SwOS UI → *Upgrade* tab →
> boot RouterOS), after which it gets the same treatment as the router.

## Components (core/docker-compose.yml)

- **mktxp** → `mikrotik` Prometheus job. Config: `core/mktxp/` (`mktxp.conf` is
  gitignored — it holds the API password; copy it from `mktxp.conf.example`).
- **snmp-exporter** → `switch-snmp` job. Config: `core/snmp-exporter/snmp.yml`.
- **loki** + **alloy** → router syslog. Alloy listens on host `514/udp+tcp`.
- Grafana datasource `Loki` (`core/grafana/provisioning/datasources/loki.yml`).
- Dashboards in `core/grafana/dashboards/network/` (folder **network** in Grafana):
  MKTXP exporter, Mikrotik logs, Switch CSS326 · SNMP.
- Alerts: `core/prometheus/rules/network-alerts.yml` (metrics) and
  `core/loki/rules/fake/router-log-alerts.yml` (router log, via Loki's ruler).

---

## 1. Router (RouterOS 7) — one-time setup

Run these in the router terminal (Winbox/WebFig → New Terminal, or SSH).

### a) Read-only API user for mktxp

```rsc
/user group add name=mktxp policy=api,read,test,winbox,!write,!policy,!sensitive
/user add name=mktxp group=mktxp password=<pick-a-strong-password>
/ip service enable api
# Optional hardening: restrict the API service to the Pi only
/ip service set api address=192.168.1.7/32
```

Then copy the example config and set that password:

```bash
cp core/mktxp/mktxp.conf.example core/mktxp/mktxp.conf
# edit core/mktxp/mktxp.conf → password = <the one above>
```

> Using API-SSL instead? Set `use_ssl = True` + `port = 8729` in `mktxp.conf`
> and run `/ip service enable api-ssl` on the router.

### b) Remote syslog → the Pi

The `remote` target's DEFAULTS already produce what Alloy parses (RFC3164) —
`remote-log-format=syslog` + `syslog-time-format=bsd-syslog` + `syslog-severity=auto`.
So just create it; don't pass `bsd-syslog=yes` (rejected in 7.23) and don't set
`remote-log-format=cef` (Alloy can't parse CEF).

```rsc
/system logging action add name=pi target=remote remote=192.168.1.7 remote-port=514
# Optional but recommended — prepend the topics (e.g. system,error) to each line,
# so logs read better in Grafana and the keyword branch of the alert has more to
# match:
/system logging action set pi add-topics-string=yes

/system logging add topics=error    action=pi
/system logging add topics=critical action=pi
/system logging add topics=warning  action=pi
# Optional — also forward info/system/firewall, but expect more volume:
# /system logging add topics=info action=pi
```

Confirm the action: `/system logging action print detail where name=pi`. The
severity-based alert relies on `syslog-severity=auto` (its default), which maps
the RouterOS topic (error/critical/warning) to the syslog severity.

Verify the router is emitting: `/log print` locally, and in Grafana →
Explore → Loki → `{job="syslog", source="router"}`.

---

## 2. Switch (SwOS 2.18) — one-time setup

SwOS is configured from its **web UI only** (no terminal). Open
`http://192.168.1.5` → **System** tab:

- **SNMP**: `Enabled`
- **Community**: pick one (default in `snmp.yml` is `public` — change both to
  match if you use something else)
- Contact / Location: optional

If you change the community from `public`, update `community:` in
`core/snmp-exporter/snmp.yml` to match, then restart `snmp-exporter`.

There is nothing to configure for logs — SwOS can't send them.

---

## 3. Deploy & verify

```bash
# From the repo root, on the Pi:
docker compose -f core/docker-compose.yml up -d mktxp snmp-exporter loki alloy
```

Checks:

- **Prometheus targets** (`http://<pi>:9090/targets`): `mikrotik` and
  `switch-snmp` should be `UP`.
- **snmp-exporter direct test**:
  `curl 'http://<pi>:9116/snmp?target=192.168.1.5&module=if_mib&auth=public_v2'`
  (only if you publish 9116; otherwise `docker exec`).
- **Grafana** → dashboards folder **network** → three dashboards populated.
- **Loki logs**: Explore → `{job="syslog", source="router"}`.
- **Alerts**: `http://<pi>:9090/alerts` (metric) and the Loki ruler alerts show
  up in Alertmanager (`http://<pi>:9093`). Firing ones reach Discord.

## Tuning notes

- The hEX RB750Gr3 has **no temperature/voltage sensor**, so
  `mktxp_system_temperature` is usually absent and `RouterHighTemperature` stays
  dormant — expected, not a fault.
- `SwitchPortDown` fires for every admin-up/link-down access port. If unused
  ports are enabled, either disable them in SwOS or narrow the alert's `ifName`.
- Loki retention is 168h (7 days), matching the powerlog Loki.
