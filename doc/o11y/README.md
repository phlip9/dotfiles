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
- Log aggregation (Loki, etc.) - separate concern
- Alerting (vmalert, alertmanager) - future work

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
| `.mcp.json` | `mcp-grafana` config for agents |

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
| `grafana-secrets-manager-key` | `grafana` | Encrypts the stored Git Sync PAT |
| `grafana-git-sync-token` | `grafana` | GitHub PAT for Git Sync |

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

Dashboards in `nixos/sauna/grafana/*.json` on our `master` branch are the
source-of-truth.

- All dashboards are `apiVersion: dashboard.grafana.app/v2`, `metadata.name` =
  uid, `spec` = dashboard.
- In Grafana they live in the `sauna` folder (uid `dotfiles`) and subdirs
  become subfolders.
- Dashboards use Grafana's on-disk JSON format, i.e., sorted keys, 2-space
  indent, `<>&` as `\u003c \u003e \u0026`.

### Sync

Grafana Git Sync to sync updates between Grafana and GitHub.

- GitHub -> Grafana: a Grafana webhook on `phlip9/dotfiles` pulls dashboard
  changes on `master` into Grafana.
- Grafana -> GitHub: every server-side save of a synced dashboard (UI, API,
  `mcp-grafana`) gets pushed as a commit on `master`.
- Only dashboards originally provisioned by Git Sync are updated by Git Sync.
  Unmanaged folders and dashboards (ex: `Scratch`) are ignored.
- Config: `services.phlip9-o11y.grafana.gitSync` in `nixos/sauna/default.nix`.
  `grafana-git-sync-setup.service` creates/updates the Grafana `Repository`
  resource, re-sends the PAT, and triggers a pull on every Grafana start
  (Grafana itself doesn't sync on startup).

### Agent Workflows

1. Metrics exploration, incidents: Agent + `mcp-grafana` read tools
   (`query_prometheus`, `get_dashboard_summary`, ...).
2. Light edits in git: edit the manifest, optionally dry-run save it on the
   live server (`just grafana-check [files...]`, default: all), commit, push.
3. UI edits: Save opens the "Provisioned dashboard" drawer. Branch `master`
   commits directly; any other branch name creates that branch + a PR.
4. Live iteration w/ an agent: the agent edits an unmanaged copy in the
   `Scratch` folder (uid `scratch`). We open the copy open in the browser.
   Agents never `update_dashboard` outside `Scratch` (= commit on `master`).

   ```bash
   # keep the result
   $ just grafana-promote scratch-nginx nixos/sauna/grafana/nginx.json
   # review + commit
   $ git diff
   ```

`grafana-check` and `grafana-promote` use basic auth if `GRAFANA_USER` +
`GRAFANA_PASSWORD` are set, else the `mcp-grafana` token
(`~/.config/grafana/mcp-sa-token`). A dry run never saves or commits, but
open browser tabs of a checked dashboard reload once.

### Imported community dashboards

| file | upstream |
|------|----------|
| `node-exporter-full.json` | [rfmoz/grafana-dashboards](https://github.com/rfmoz/grafana-dashboards/blob/master/prometheus/node-exporter-full.json) |
| `nginx.json` | [nginx-prometheus-exporter](https://github.com/nginx/nginx-prometheus-exporter/blob/main/grafana/dashboard.json) |
| `postgres-overview.json` | [postgres_exporter mixin](https://github.com/prometheus-community/postgres_exporter/blob/master/postgres_mixin/dashboards/postgres-overview.json) |
| `victoriametrics-single-node.json` | [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/master/dashboards/vm/victoriametrics.json) |

## Future Work

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

1. Create a fine-grained PAT:
   <https://github.com/settings/personal-access-tokens/new>
   - Resource owner: `phlip9`
   - Repository access: `phlip9/dotfiles`
   - Permissions:
     - Administration: Read
     - Contents: Read and write
     - Metadata: Read
     - Pull requests: Read and write
     - Webhooks: Read and write
   - Expiry: 1 year

2. Add the secrets:

   ```bash
   $ sops set nixos/sauna/secrets.yaml '["grafana-secrets-manager-key"]' \
       "\"$(head -c 32 /dev/urandom | base64 -w0)\""
   $ sops nixos/sauna/secrets.yaml   # grafana-git-sync-token: github_pat_...
   ```

3. Merge `nixos/sauna/grafana/` to `master` (Grafana syncs from there), then
   `just deploy sauna`.

4. Check:

   ```bash
   $ ssh sauna systemctl status grafana-git-sync-setup.service
   $ curl -s -u phlip9 https://grafana.phlip9.com/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories/dotfiles \
       | jq .status
   ```

   Expect `health.healthy: true` and `webhook.id` set. The hook is listed
   under GitHub > dotfiles > Settings > Webhooks. Grafana owns it; don't
   edit it there.

5. First time only: delete the pre-existing dashboards in the UI
   (Dashboards > select all > Delete). Git Sync can't adopt a uid that
   already exists. Then Administration > Provisioning > dotfiles > Pull.
   Deleted dashboards stay under Dashboards > Recently deleted.

6. Round trip: edit a panel, Save, branch `master`, commit message, Save.
   `git pull` shows the commit. Push a manifest edit; Grafana shows it
   within seconds.

### Rotate Git Sync secrets

- PAT: new token (step 1 above), `sops nixos/sauna/secrets.yaml`, `just
  deploy sauna`. The secret change restarts the setup unit, which re-sends
  the token.
- Secrets-manager key: in `o11y.nix` add a `secret_key.v3` provider,
  switch `encryption_provider` to it, keep `v2` so old data keys stay
  readable. Deploy; the PAT is re-stored under the new key.

### Agent access (mcp-grafana)

1. Grafana > Administration > Users and access > Service accounts > Add
   service account: name `phlipdesk`, role `Editor`. Add service account
   token > Generate. Copy the `glsa_...` token (shown once).

2. On each machine that runs agents (e.g. phlipdesk, sauna):

   ```bash
   $ cd ~/.config
   $ mkdir -m 0700 grafana
   # paste + Ctrl-D
   $ (umask 077 && cat > ~/.config/grafana/mcp-sa-token)
   # strip trailing newline just in case
   $ perl -0777 -i -pe 's/\s+\z//' -- ~/.config/grafana/mcp-sa-token
   ```

3. In the dotfiles repo run e.g. `claude`, approve the project MCP server
   `grafana` once, then `claude mcp list` -> `grafana ... connected`. Ask for
   `user_info`. Expect service account `phlipdesk`, role Editor.

Read tools are pre-allowed in `.claude/settings.json`; write tools prompt.
Read-only variant: role `Viewer` + `--disable-write` in `.mcp.json`.

The Scratch workflow needs no setup: the agent creates the `Scratch` folder
on first use, and `just grafana-check` / `just grafana-promote` reuse the
token file.
