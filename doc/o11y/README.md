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
    │ PromQL queries
    ▼
victoriametrics (127.0.0.1:8428)
    │ promscrape (15s interval)
    ├── victoriametrics   localhost:8428/metrics
    ├── node-exporter     localhost:9100/metrics
    ├── nginx-exporter    localhost:9113/metrics
    └── grafana           localhost:3000/metrics
```

Target machine: `omnara1` (Hetzner 6c/12t, 2x894 GiB NVMe RAID 0)
DNS: `grafana.phlip9.com`

## Components

### VictoriaMetrics (metrics storage + scraper)

Single-node binary that handles ingestion, storage, and querying.
Prometheus-compatible API — works as a drop-in Grafana datasource
using the Prometheus type.

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
- Provisioned datasource: VictoriaMetrics as Prometheus type
- Provisioned dashboards: node-exporter, VictoriaMetrics
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

## Implementation Files

| File | Purpose |
|------|---------|
| `nixos/mods/o11y.nix` | NixOS module: VM + Grafana + exporters |
| `nixos/mods/default.nix` | Import o11y module |
| `nixos/tests/o11y.nix` | NixOS VM test |
| `nixos/omnara1/default.nix` | Enable `services.phlip9-o11y` |
| `nixos/omnara1/secrets.yaml` | sops secrets for Grafana |
| `doc/o11y/README.md` | This document |

## Secrets

Two new sops secrets in `nixos/omnara1/secrets.yaml`:

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

## Scrape Config

```yaml
scrape_configs:
  - job_name: victoriametrics
    static_configs:
      - targets: ["127.0.0.1:8428"]

  - job_name: node-exporter
    static_configs:
      - targets: ["127.0.0.1:9100"]

  - job_name: nginx-exporter
    static_configs:
      - targets: ["127.0.0.1:9113"]

  - job_name: grafana
    static_configs:
      - targets: ["127.0.0.1:3000"]
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

## Implementation Plan

### Phase 1: VM test (nixos/tests/o11y.nix)

Single-VM test with VictoriaMetrics + node-exporter + Grafana.
No nginx, no TLS, no oauth2-proxy — those are production concerns
tested upstream.

Verifications:
1. All services start (`wait_for_unit`)
2. VictoriaMetrics `/ping` responds
3. node-exporter metrics visible: query `up{job="node-exporter"}`
4. Grafana API accessible as admin
5. Provisioned datasource healthy (`/api/datasources/uid/*/health`)

### Phase 2: NixOS module (nixos/mods/o11y.nix)

Options:
- `services.phlip9-o11y.enable`
- `services.phlip9-o11y.grafana.domain`

Configures all components. nginx vhost only created when
`grafana.domain` is set.

### Phase 3: omnara1 deployment

1. Add sops secrets for Grafana
2. Enable module in `nixos/omnara1/default.nix`
3. Enable `nginx.statusPage` for nginx-exporter
4. DNS: point `grafana.phlip9.com` to omnara1
5. Deploy via `just deploy`

### Future Work

- **oauth2-proxy**: Protect Grafana behind GitHub OAuth. Either
  share the existing buildbot oauth2-proxy instance (via the
  `oauth2-proxy-nginx` NixOS module) or use Grafana's built-in
  GitHub OAuth support.
- **Alerting**: vmalert + alertmanager for on-call notifications.
- **Additional exporters**: postgres-exporter, systemd-exporter,
  blackbox-exporter for endpoint probing.
- **Log aggregation**: Loki + promtail, separate from metrics.
