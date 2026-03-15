# Metrics Observability Stack

## Requirements

- Single-node metrics collection, storage, and visualization
- Up to 1 TiB storage, 1-3 months retention
- Metrics are non-critical: no backups or redundancy
- Secure by default: all services on localhost, only nginx public
- Use existing NixOS modules
- Secrets via sops-nix
- Operationally simple: minimal moving parts, easy to debug

## Non-Goals

- High availability, clustering, or replication
- Log aggregation (Loki, etc.) — separate concern
- Alerting (vmalert, alertmanager) — future work
- oauth2-proxy integration — deferred, add later

## Architecture

```
internet
    │
    ▼
nginx (443, TLS/ACME)
    │
    ▼
grafana (127.0.0.1:3000)
    │ MetricsQL queries
    ▼
victoriametrics (127.0.0.1:8428)
    │ promscrape (15s interval)
    ├── victoriametrics   localhost:8428/metrics
    ├── grafana           localhost:3000/metrics
    ├── node-exporter     localhost:9100/metrics
    │   ...
    └── nginx-exporter    localhost:9113/metrics
```

Target machine: `omnara1` (Hetzner 6c/12t, 2x894 GiB NVMe RAID 0)
DNS: `grafana.phlip9.com`

## Files

| File | Purpose |
|------|---------|
| `nixos/mods/o11y.nix` | NixOS module: VM + Grafana + exporters |
| `nixos/tests/o11y.nix` | NixOS VM test |
| `nixos/omnara1/default.nix` | NixOS machine config |

## Components

### VictoriaMetrics (metrics storage + scraper)

Single-node binary that handles ingestion, storage, and querying.
Prometheus-compatible API.

NixOS module: `services.victoriametrics`

Config:
- `listenAddress`: `127.0.0.1:8428`
- `retentionPeriod`: `3` (3 months)
- `prometheusConfig`: scrape configs for all local targets
- Systemd hardening: DynamicUser, ProtectSystem, MemoryDeny, etc.

Storage sizing: with ~4 exporters at 15s scrape interval, expect
1-5 GiB/month. 3 months retention ≈ 5-15 GiB. The 1 TiB budget is
for long-term growth as we add more services and exporters.

Key endpoints:
- `/ping` — health check
- `/api/v1/query` — instant query (PromQL/MetricsQL)
- `/api/v1/query_range` — range query
- `/api/v1/write` — Prometheus remote write
- `/metrics` — self-metrics
- `/vmui` — built-in query UI

### Grafana (visualization)

NixOS module: `services.grafana`

Config:
- Listen: `127.0.0.1:3000`
- Database: sqlite3 (single user, no need for postgres)
- Provisioned datasource: VictoriaMetrics
- Admin password: sops secret via `$__file{path}` provider
- Secret key: sops secret via `$__file{path}` provider
- Disable sign-up, disable gravatar, disable analytics

### prometheus-node-exporter (system metrics)

CPU, memory, disk, network, filesystem metrics.

NixOS module: `services.prometheus.exporters.node`
Listen: `127.0.0.1:9100`

### prometheus-nginx-exporter (nginx metrics)

Scrapes nginx `stub_status` for connection/request metrics.

NixOS module: `services.prometheus.exporters.nginx`
Listen: `127.0.0.1:9113`

Requires `services.nginx.statusPage = true` to expose
`/nginx_status` on localhost.

### nginx (TLS termination + reverse proxy)

Already running on omnara1 for buildbot CI. Add a new virtualHost
for `grafana.phlip9.com` with:
- `forceSSL = true`, `enableACME = true`
- Proxy to `http://127.0.0.1:3000`

## Secrets

| Secret | Owner | Purpose |
|--------|-------|---------|
| `grafana-admin-password` | `grafana` | Grafana admin login |
| `grafana-secret-key` | `grafana` | Grafana cookie/token signing |

Loaded into Grafana via the `$__file{path}` provider pattern,
which reads the secret from disk at runtime without leaking into
the Nix store. Example:

```nix
services.grafana.settings.security = {
  admin_password = "$__file{${config.sops.secrets.grafana-admin-password.path}}";
  secret_key = "$__file{${config.sops.secrets.grafana-secret-key.path}}";
};
```

## Default Dashboards

Provisioned via Grafana's dashboard provisioning:

1. **Node Exporter Full** (grafana.com gnetId: 1860)
   Standard community dashboard for prometheus-node-exporter.
   CPU, memory, disk I/O, network, filesystem usage.

2. **VictoriaMetrics Single** (grafana.com gnetId: 10229)
   Official VM dashboard. Ingestion rate, query performance,
   storage size, active time series, cache hit rates.

Both downloaded at build time and provisioned as JSON files.

### Future Work

- **oauth2-proxy**: Protect Grafana behind GitHub OAuth. Either
  share the existing buildbot oauth2-proxy instance (via the
  `oauth2-proxy-nginx` NixOS module) or use Grafana's built-in
  GitHub OAuth support.
- **Alerting**: vmalert + alertmanager for on-call notifications.
- **Additional exporters**: postgres-exporter, systemd-exporter,
  blackbox-exporter for endpoint probing.
- **Log aggregation**: Loki + promtail, separate from metrics.

## Runbooks

### Setup

1. Add the `phlip9-o11y` service

2. Re-deploy: (ex: `just deploy omnara1`)

3. Open grafana (ex: <https://grafana.phlip9.com>)

4. For setup, login with username=admin and the admin password from sops
   secrets.yaml:

   ```bash
   $ sops --decrypt nixos/omnara1/secrets.yaml | yq -r '.grafana-admin-password' | wl-copy
   ```

5. Create `phlip9` user

   * Grafana > Administration > Users and access > Users > New user

     Name: Philip Kannegaard Hayes
     Email: philiphayes9@gmail.com
     Username: phlip9
     Password: (redacted)

     > Create user

     Permissions > Grafana Admin > Change > Yes

6. Logout and Login as `phlip9`

7. Update settings:

   Administration > General > Default preferences
   * Interface theme: Gilded grove


### Dashboards

After importing a new dashboard, change the datasource type under "Variables"
to `victoriametrics-metrics-datasource`.

* [Node Exporter Full](https://github.com/rfmoz/grafana-dashboards/blob/master/prometheus/node-exporter-full.json)

* [NGINX](https://github.com/nginx/nginx-prometheus-exporter/blob/main/grafana/dashboard.json)

* [Postgres Overview](https://github.com/prometheus-community/postgres_exporter/blob/master/postgres_mixin/dashboards/postgres-overview.json)

* [VictoriaMetrics - single-node (VM)](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/master/dashboards/vm/victoriametrics.json)
