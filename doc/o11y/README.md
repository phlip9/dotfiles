# Observability Stack

## Requirements

- Single-node metrics collection, storage, and visualization
- Continuous profiling of every process: on-CPU + off-CPU, symbolized, flame
  graphs in Grafana. < 5% CPU
- Up to 1 TiB storage, 1-3 months retention
- Metrics + profiles are non-critical: no backups or redundancy
- Secure by default: all services on localhost, only nginx public
- Use existing NixOS modules
- Secrets via sops-nix
- Operationally simple: minimal moving parts, easy to debug

## Non-Goals

- High availability, clustering, or replication
- Log aggregation (Loki, etc.) - separate concern

## Architecture

```
internet
    |
    v
nginx (443, TLS/ACME)
    |
    v
grafana (127.0.0.1:3000)
    | MetricsQL queries                 | profile queries
    v                                   v
victoriametrics (127.0.0.1:8428)    pyroscope (127.0.0.1:4040)
    | <-- vmalert rules,                ^ push, see Profiling
    |     see Alerting                  |
    | promscrape (1m interval)          alloy (127.0.0.1:12345, eBPF)
    +-- victoriametrics   localhost:8428/metrics
    +-- grafana           localhost:3000/metrics
    +-- node-exporter     localhost:9100/metrics
    +-- nginx-exporter    localhost:9113/metrics
    +-- postgres-exporter localhost:9187/metrics
    +-- nixbot            https://127.0.0.1:443/metrics
    +-- niks3             [::1]:5751/metrics
    +-- rbitcoin          localhost:9332/metrics
    +-- vmalert           localhost:8880/metrics
    +-- alertmanager      localhost:9093/metrics
    +-- pyroscope         localhost:4040/metrics
    +-- alloy             localhost:12345/metrics
    +-- blackbox          localhost:9115/probe?target=<https url>
```

Target machine: `sauna` (Hetzner 6c/12t, 2x894 GiB NVMe RAID 0)
DNS: `grafana.phlip9.com`

## Files

| File | Purpose |
|------|---------|
| `nixos/mods/o11y/default.nix` | NixOS module: VM + Grafana + exporters |
| `nixos/mods/o11y/alerting.nix` | Alerting: vmalert, Alertmanager, host ping |
| `nixos/mods/o11y/rules.nix` | Alert rules + inhibitions |
| `nixos/mods/o11y/alertmanager.tmpl` | Discord message templates |
| `nixos/mods/o11y/tests/rules.yml` | Rule unit tests (vmalert-tool) |
| `nixos/mods/o11y/profiling.nix` | Profiling: Pyroscope, Alloy eBPF collector |
| `nixos/pkgs/grafana-alloy/` | Alloy (ahead of nixpkgs) |
| `nixos/pkgs/grafana-pyroscope-datasource/` | Grafana Pyroscope datasource |
| `nixos/tests/o11y.nix` | NixOS container test |
| `nixos/tests/o11y-alerting.nix` | NixOS container test: alert delivery |
| `nixos/tests/o11y-alerting-unit.nix` | Offline check: rules + routing |
| `nixos/tests/o11y-profiling.nix` | NixOS container test: Pyroscope |
| `nixos/tests/o11y-profiling-ebpf.nix` | NixOS VM test: Alloy eBPF end to end |
| `nixos/sauna/default.nix` | NixOS machine config |
| `nixos/sauna/grafana/` | Dashboards (Git Sync manifests) |
| `.mcp.json` | `mcp-grafana` config for agents (points them at the skill) |
| `.agents/skills/grafana-dashboard/` | agent skill build/rework dashboards |
| `just/grafana-*.sh`, `just/grafana.jq`, `pkgs/grafana-screenshot/` | dashboard tools |

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
- Provisioned datasources: VictoriaMetrics (default), Alertmanager, Pyroscope
- Admin password: sops secret via `$__file{path}` provider
- Secret key: sops secret via `$__file{path}` provider
- Disable sign-up, disable gravatar, disable analytics

### nginx (TLS termination + reverse proxy)

Already running on sauna for nixbot CI. Add a new virtualHost
for `grafana.phlip9.com` with:
- `forceSSL = true`, `enableACME = true`
- Proxy to `http://127.0.0.1:3000`

## Secrets

| Secret | Used by | Purpose |
|--------|---------|---------|
| `grafana-admin-password` | `grafana` | Grafana admin login |
| `grafana-secret-key` | `grafana` | Grafana cookie/token signing |
| `grafana-secrets-manager-key` | `grafana` | Encrypts the stored Git Sync PAT |
| `grafana-git-sync-token` | `grafana` | GitHub PAT for Git Sync |
| `alertmanager-discord-webhook-url` | `alertmanager` | Discord webhook |
| `alertmanager-env` | `alertmanager` | `DISCORD_USER_ID` for mentions |
| `healthchecks-watchdog-ping-url` | `alertmanager` | hc-ping, Watchdog alert |
| `healthchecks-host-ping-url` | `healthchecks-host-ping` | hc-ping, host timer |

All stay root-owned sops files. Units read them through systemd
`LoadCredential` (`/run/credentials/<unit>/...`), except
`alertmanager-env`, an `EnvironmentFile` that Alertmanager's config gets
envsubst'ed with.

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
  (Grafana itself doesn't sync on startup). It also sets the org home
  dashboard (`gitSync.homeDashboard`): `overview`. A user's own home
  dashboard preference (Profile -> Preferences) overrides it.

### Agent Workflows

1. Metrics exploration, incidents: Agent + `mcp-grafana` read tools
   (`query_prometheus`, `get_dashboard_summary`, ...).
2. Profiles: `mcp-grafana` `pyroscope` tools; ids, labels, and query
   shapes in the `grafana-dashboard` skill's "Profiles" section.
3. Edits in git: edit the manifest in place (agents: `grafana-outline` to
   map it, the `grafana-dashboard` skill's `dash.py` to edit it), dry-run
   save it on the live server (`just grafana-check [files...]`, default:
   all), commit, push.
4. UI edits: Save opens the "Provisioned dashboard" drawer. Branch `master`
   commits directly; any other branch name creates that branch + a PR.
5. Live iteration w/ an agent: the agent edits an unmanaged copy in the
   `Scratch` folder (uid `scratch`). We open the copy in the browser.
   Agents never write outside `Scratch` (= commit on `master`). The
   workflow lives in the `grafana-dashboard` skill; each tool documents
   itself (`--help`, script header). Cheat sheet:

   ```bash
   $ just grafana-outline nixos/sauna/grafana/nginx.json  # map it
   $ just grafana-push nixos/sauna/grafana/nginx.json     # -> scratch-nginx
   $ just grafana-queries --from now-7d scratch-nginx     # ok/EMPTY/FAIL
   $ just grafana-screenshot scratch-nginx -o tmp/nginx.png
   $ just grafana-resave scratch-nginx                    # UI defaults
   $ just grafana-promote scratch-nginx nixos/sauna/grafana/nginx.json
   ```

The `grafana-*` tools use basic auth if `GRAFANA_USER` + `GRAFANA_PASSWORD`
are set, else the `mcp-grafana` token (`~/.config/grafana/mcp-sa-token`). A
dry run never saves or commits, but open browser tabs of a checked dashboard
reload once. Grafana has no image renderer plugin; `grafana-screenshot`
renders the real UI w/ playwright instead.

### Imported community dashboards

| file | upstream |
|------|----------|
| `node-exporter-full.json` | [rfmoz/grafana-dashboards](https://github.com/rfmoz/grafana-dashboards/blob/master/prometheus/node-exporter-full.json) |
| `nginx.json` | [nginx-prometheus-exporter](https://github.com/nginx/nginx-prometheus-exporter/blob/main/grafana/dashboard.json) |
| `postgres-overview.json` | [postgres_exporter mixin](https://github.com/prometheus-community/postgres_exporter/blob/master/postgres_mixin/dashboards/postgres-overview.json) |
| `victoriametrics-single-node.json` | [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/master/dashboards/vm/victoriametrics.json) |

## Alerting

vmalert evaluates rules against VictoriaMetrics, Alertmanager groups, runs
inhibitions, and then routes alerts. Discord is the only alert channel.
A watchdog on sauna pings healthchecks.io.

```
victoriametrics <--query-- vmalert (:8880) --> alertmanager (:9093)
   ^                         |                   |
   +---- ALERTS series ------+                   +-- Watchdog --> hc
                                                 +-- page ------> #alerts
                                                 +-- warn/info -> #alerts
healthchecks-host-ping.timer (5m) --> hc, if VM/vmalert/AM are healthy
hc (healthchecks.io), on missed pings --> #watchdog
```

- Severity labels:
  - `page` (disk full, memory, broken fs or RAID, cert expiry)
  - `warn` (look today)
  - `info` (context)
- Discord message per (severity, alertname) group, pages repeat x1h else x12h.
- `page`s get not @mention at Night (23:00-09:00 America/Los_Angeles)
- Alerts for root causes hide symptom alerts via inhibitions.
- See alert history with `ALERTS{alertstate="firing"}` in Grafana. Active
  alerts + silences: Grafana > Alerting, `Alertmanager` datasource.

### Add a rule

1. Write the expr, run it live, and back-test it:

   ```bash
   $ curl -s --data-urlencode 'query=<expr>' http://127.0.0.1:8428/api/v1/query
   $ curl -s --data-urlencode 'query=count_over_time((<expr>)[90d:5m])' \
       http://127.0.0.1:8428/api/v1/query
   ```

2. Add it to a group in `nixos/mods/o11y/rules.nix`: `alert`, `expr`,
   `for`, `labels.severity`, and `annotations` w/ `summary` (what) and
   `description` (where to look). Other modules can append groups to
   `services.vmalert.instances."".rules.groups`.

3. `just alerting-test`: `vmalert -dryRun`, the unit tests, and `amtool`
   config + routing checks against sauna's rendered config. Non-obvious
   expr: add a case to `nixos/mods/o11y/tests/rules.yml` (annotations must
   match exactly). Routing or template changes: also
   `nix build -f . nixosTests.o11y-alerting -L`.

### Silence

- Discord: each alert's `silence` link opens a prefilled Grafana form.
- Grafana > Alerting > Silences, Alertmanager `Alertmanager`.
- On sauna:

  ```bash
  $ amtool() {
      nix shell -f ~/dev/dotfiles pkgsUnstable.prometheus-alertmanager -c \
        amtool --alertmanager.url=http://127.0.0.1:9093 "$@"
    }
  $ amtool alert query
  $ amtool silence add alertname=TargetDown job=nixbot -d 2h -c "nixbot upgrade"
  $ amtool silence query
  ```

- Downtime that stops the pipeline (vmalert/Alertmanager/VM/host): pause
  both checks in healthchecks.io too.

## Profiling

Alloy (`pyroscope.ebpf`, 127.0.0.1:12345) samples on-CPU + off-CPU stacks of
every process, symbolizes them on the host, labels them w/ their systemd
unit, and pushes one pprof per (labels, profile type) every 15s to Pyroscope
(127.0.0.1:4040, 30d retention). Grafana: datasource `pyroscope`, Profiles
Drilldown, `profiling` dashboard. Config + the why of every knob, cap, and
hardening flag: `nixos/mods/o11y/profiling.nix`.

- Profile types: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`,
  `offcpu:offcpu:nanoseconds::` (blocked time, sampled at p=0.02).
- Labels: `service_name` = unit from the cgroup (`getty@tty1` -> `getty@`,
  sessions -> `user-phlip9`, PID 1 -> `systemd`, kernel threads -> `kernel`,
  procs younger than a 2s /proc rescan -> `ebpf/unspecified`), `exe` = binary
  basename, `host`. No `pid`.
- Symbols: `.symtab` or Go pclntab, no DWARF yet. Rust built w/ `-C
  strip=symbols` needs the `nixos/pkgs/rbitcoin.nix` treatment.
- Alloy is non-root but near root-equivalent (reads any process memory).
- Sadly pyroscope has no storage cap, only a max retention period.

### Query profiles from the CLI

```bash
$ profilecli() {
    nix shell -f ~/dev/dotfiles pkgsUnstable.pyroscope -c profilecli "$@"
  }
# on sauna
$ export PROFILECLI_URL=http://127.0.0.1:4040
# elsewhere, via the Grafana datasource proxy
$ export PROFILECLI_URL=https://grafana.phlip9.com/api/datasources/proxy/uid/pyroscope \
    PROFILECLI_TOKEN="$(cat ~/.config/grafana/mcp-sa-token)"
$ profilecli query top --from now-1h --query '{service_name="nix-daemon"}'
$ profilecli query top --from now-1h \
    --profile-type offcpu:offcpu:nanoseconds::
$ profilecli query profile --from now-15m \
    --query '{service_name="nix-daemon"}' --output pprof=tmp/nd.pprof
$ nix shell -f ~/dev/dotfiles pkgs.go -c \
    go tool pprof -symbolize=none -top tmp/nd.pprof
```

## Future Work

- **Additional exporters**: SMART/NVMe wear (`exporters.smartctl`), nginx
  per-vhost status codes + latency (access log or VTS module).
- **Log aggregation**: Loki + promtail, separate from metrics.
- **Profiling**: size retention, `MemoryMax`, and `PyroscopeDiskHigh` from
  measured data; DWARF inline frames; phlipdesk push; app-side memory/mutex
  pprof.

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

### Alerting setup (Discord + healthchecks.io)

Setup secrets used by alerting.

1. Discord: create a server (or reuse one) with two text channels:
   `#alerts` and `#watchdog`.

2. Webhook for `#alerts`: channel settings > Integrations > Webhooks > New
   Webhook, name `alertmanager`, Copy Webhook URL
   (`https://discord.com/api/webhooks/<id>/<token>`)

3. Your user id: User Settings > Advanced > Developer Mode on, then
   right-click your name > Copy User ID (a number).

4. Notifications, on every device: `#alerts` > Notification Settings >
   Only @mentions. `#watchdog` > All Messages. Phone: Do Not Disturb
   23:00-09:00 (Discord has no schedule; this is the night gate for
   `#watchdog`).

5. healthchecks.io: sign up (free plan), project `sauna`.
   - Integrations > Add Integration > Discord > Add to Discord, pick the
     server and `#watchdog`.
   - Add Check `sauna-watchdog`: Period 5 min, Grace 5 min.
   - Add Check `sauna-host`: Period 5 min, Grace 5 min.
   - Both checks: Integrations > enable Discord. Copy each Ping URL
     (`https://hc-ping.com/<uuid>`).

6. Secrets: `sops nixos/sauna/secrets.yaml`

   ```yaml
   alertmanager-discord-webhook-url: https://discord.com/api/webhooks/<id>/<token>
   alertmanager-env: |
       DISCORD_USER_ID=<number>
   healthchecks-watchdog-ping-url: https://hc-ping.com/<uuid>
   healthchecks-host-ping-url: https://hc-ping.com/<uuid>
   ```

7. Deploy, then try exercising alerts
   - `systemctl stop prometheus-nginx-exporter` for ~5 min
   - `systemctl stop victoriametrics` for ~15 min
   - `systemctl stop alertmanager` for ~10 min
   - `systemctl stop healthchecks-host-ping.timer` for ~10 min


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
