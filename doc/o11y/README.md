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

## Architecture

```
internet
    |
    v
nginx (443, TLS/ACME)
    |
    v
grafana (127.0.0.1:3000)
    | MetricsQL queries
    v
victoriametrics (127.0.0.1:8428)
    | promscrape (15s interval)
    +-- victoriametrics   localhost:8428/metrics
    +-- grafana           localhost:3000/metrics
    +-- node-exporter     localhost:9100/metrics
    +-- nginx-exporter    localhost:9113/metrics
    +-- postgres-exporter localhost:9187/metrics
    +-- nixbot            https://127.0.0.1:443/metrics
    +-- niks3             [::1]:5751/metrics
```

Target machine: `sauna` (Hetzner 6c/12t, 2x894 GiB NVMe RAID 0)
DNS: `grafana.phlip9.com`

## Files

| File | Purpose |
|------|---------|
| `nixos/mods/o11y.nix` | NixOS module: VM + Grafana + exporters |
| `nixos/tests/o11y.nix` | NixOS VM test |
| `nixos/sauna/default.nix` | NixOS machine config |
| `nixos/sauna/grafana/` | Dashboards (Git Sync manifests) |
| `.mcp.json` | mcp-grafana config for Claude Code |
| `doc/o11y/dashboards.md` | Dashboards research + design |

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

### nixbot and niks3

Scraping is enabled automatically when each service is enabled.

Useful queries in Grafana Explore:

- `up{job=~"nixbot|niks3"}`: scrape health
- `nixbot_queue_depth`: pending/running builds
- `nixbot_upload_queue_depth`: paths awaiting cache upload
- `niks3_cache_objects`: objects tracked by the cache
- `niks3_cache_logical_bytes`: logical cache size

`nixosTests.nixbot` checks that both services' metrics reach VictoriaMetrics
after a successful build and cache upload.

### nginx (TLS termination + reverse proxy)

Already running on sauna for nixbot CI. Add a new virtualHost
for `grafana.phlip9.com` with:
- `forceSSL = true`, `enableACME = true`
- Proxy to `http://127.0.0.1:3000`

## Secrets

| Secret | Owner | Purpose |
|--------|-------|---------|
| `grafana-admin-password` | `grafana` | Grafana admin login |
| `grafana-secret-key` | `grafana` | Grafana cookie/token signing |
| `grafana-secrets-manager-key` | `grafana` | Secrets manager key (Git Sync) |
| `grafana-git-sync-token` | `grafana` | GitHub fine-grained PAT for Git Sync |

Loaded into Grafana via the `$__file{path}` provider pattern,
which reads the secret from disk at runtime without leaking into
the Nix store. Example:

```nix
services.grafana.settings.security = {
  admin_password = "$__file{${config.sops.secrets.grafana-admin-password.path}}";
  secret_key = "$__file{${config.sops.secrets.grafana-secret-key.path}}";
};
```

## Dashboards

Dashboards are managed by Grafana 13 "Git Sync" (API group
`provisioning.grafana.app`). Design + research: `doc/o11y/dashboards.md`.

- Source of truth: `nixos/sauna/grafana/*.json` on `master`, one k8s-style
  manifest per dashboard (`apiVersion: dashboard.grafana.app/v1|v2`,
  `metadata.name` = uid, `spec` = dashboard JSON). Subdirs become folders.
- Grafana registers its own push + pull_request webhook on the GitHub repo
  (HMAC-verified, no Grafana login; nginx proxies `/` so nothing to add) and
  imports changes within seconds; a 60s poll is the fallback. No redeploy
  needed to change a dashboard.
- Saving a synced dashboard in the UI opens the "Provisioned dashboard"
  drawer: pick the branch (`master` = direct commit, anything else = new
  branch + PR) and a commit message.
- API writes to a synced dashboard via the k8s-style API (`PUT
  /apis/dashboard.grafana.app/...`, annotations preserved) are re-routed
  into commits. The legacy `POST /api/dashboards/db` is rejected with 400
  "Cannot save provisioned dashboard"; mcp-grafana's `update_dashboard` uses
  the legacy API for v1 dashboards, so agents edit synced v1 dashboards by
  editing the manifest in git instead. New (v2) dashboards created via
  `update_dashboard` do become commits; its `message` is the commit message.
- Schema policy: imported community dashboards stay v1 and are patched in
  place; the VictoriaMetrics dashboard and new dashboards are v2.
- The Repository resource is created/updated at boot by
  `grafana-git-sync-setup.service` (`services.phlip9-o11y.grafana.gitSync`),
  so the setup is declarative except for the two sops secrets.
- Agent access: Claude Code uses `mcp-grafana` (stdio, `.mcp.json`) with a
  service account token in `~/.config/grafana/mcp-sa-token` for reads,
  metric queries, and new dashboards; existing dashboards are edited as
  files in `nixos/sauna/grafana/` + commit + push (Grafana pulls in <=60s).

Current dashboards (community imports, datasource switched to
`victoriametrics-metrics-datasource`):

| file | upstream |
|------|----------|
| `node-exporter-full.json` | [rfmoz/grafana-dashboards](https://github.com/rfmoz/grafana-dashboards/blob/master/prometheus/node-exporter-full.json) |
| `nginx.json` | [nginx-prometheus-exporter](https://github.com/nginx/nginx-prometheus-exporter/blob/main/grafana/dashboard.json) |
| `postgres-overview.json` | [postgres_exporter mixin](https://github.com/prometheus-community/postgres_exporter/blob/master/postgres_mixin/dashboards/postgres-overview.json) |
| `victoriametrics-single-node.json` | [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/master/dashboards/vm/victoriametrics.json) |

### Future Work

- **Alerting**: vmalert + alertmanager for on-call notifications.
- **Additional exporters**: systemd-exporter, blackbox-exporter for endpoint
  probing.
- **Log aggregation**: Loki + promtail, separate from metrics.

## Runbooks

### Setup

1. Add the `phlip9-o11y` service

2. Re-deploy: (ex: `just deploy sauna`)

3. Open grafana (ex: <https://grafana.phlip9.com>)

4. For setup, login with username=admin and the admin password from sops
   secrets.yaml:

   ```bash
   $ sops --decrypt nixos/sauna/secrets.yaml | yq -r '.grafana-admin-password' | wl-copy
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


### Git Sync setup

1. Add the two sops secrets (see `doc/SECRETS.md`):

   ```bash
   $ sops set nixos/sauna/secrets.yaml '["grafana-secrets-manager-key"]' \
       "\"$(head -c 32 /dev/urandom | base64 -w0)\""
   $ sops nixos/sauna/secrets.yaml  # add grafana-git-sync-token: github_pat_..
   ```

   (Use the editor for the PAT so it stays out of shell history.)

   GitHub PAT: Settings > Developer settings > Fine-grained tokens. Resource
   owner `phlip9`, repository access: only `phlip9/dotfiles`. Permissions:
   Administration: Read; Contents: Read and write; Metadata: Read; Pull
   requests: Read and write; Webhooks: Read and write. (Webhooks RW is only
   offered to repo admins; Administration R is for branch-protection
   checks. Both can be dropped with `gitSync.github.webhook = false`.) Set
   a long expiry and note the rotation date.

   The secrets-manager key must be in place before the first Git Sync
   repository is created. To rotate it later, add a `secret_key.v3` provider
   and switch `encryption_provider` to it, keeping `v2` so older data keys
   stay readable; the setup unit re-sends the PAT on every run, so it gets
   re-encrypted under the new key.

2. Deploy: `just deploy sauna`. Check:

   ```bash
   $ systemctl status grafana-git-sync-setup.service
   $ curl -s -u admin:$PW -H 'Host: grafana.phlip9.com' \
       http://127.0.0.1:3000/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories/dotfiles \
       | jq .status
   ```

   `status.health.healthy` should be true and `status.webhook` should carry
   the hook id + URL (`https://grafana.phlip9.com/apis/.../webhook`). The
   hook also shows up under GitHub > dotfiles > Settings > Webhooks with a
   green check after the first delivery. Grafana owns it: don't edit it by
   hand; it is removed when the Repository is deleted or webhooks are
   disabled.

3. One-time migration of pre-existing (unmanaged) dashboards: Git Sync can
   not adopt a dashboard whose uid already exists outside the repo. The
   manifests in `nixos/sauna/grafana/` were exported from the live instance,
   so delete the originals in the UI (Dashboards > select > Delete), then
   wait one sync interval (or Administration > Provisioning > repository >
   Pull). Deleted dashboards stay restorable under "Recently deleted".

4. Verify the round trip: edit a panel in the UI, Save, pick `master`, write a
   commit message, then `git pull` and confirm the commit. Then push a
   manifest change from the desktop and confirm it shows in Grafana within
   a few seconds (`status.webhook.lastEvent` updates).

### Agent access (mcp-grafana)

1. Service account: Administration > Users and access > Service accounts >
   Add service account. Name `claude-code`, role `Editor` (OSS has no
   finer-grained RBAC for service accounts; `Viewer` + `--disable-write` in
   `.mcp.json` for a read-only variant).

2. Add service account token > Generate. Copy the `glsa_...` token (shown
   once). Install on each machine that runs Claude Code:

   ```bash
   $ mkdir -p -m 0700 ~/.config/grafana
   $ (umask 077 && cat > ~/.config/grafana/mcp-sa-token)   # paste, Ctrl-D
   ```

   mcp-grafana re-reads the file on every request; rotate by overwriting.

3. `hms` to install `mcp-grafana` (`pkgsUnstable.mcp-grafana`; stable is too
   old). In the dotfiles repo, `claude` prompts once to trust the project
   server `grafana`. `claude mcp list` should show it connected; in a session
   `user_info` should report service account `claude-code`, role Editor. A
   401 means a bad token file; a redirect error means `GRAFANA_URL` is not
   the final https URL.

4. Read-only tools are pre-allowed in `.claude/settings.json`; writes
   (`update_dashboard`, `create_folder`, ...) prompt every time. Git Sync
   turns each write into a commit on `master`.
