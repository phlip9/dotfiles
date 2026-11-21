# Observability Stack

## Contents

- [Requirements](#requirements)
- [Non-Goals](#non-goals)
- [Architecture](#architecture)
- [Files](#files)
- [Components](#components)
  - [vmagent](#vmagent-scraper)
  - [VictoriaMetrics](#victoriametrics-metrics-storage)
  - [Grafana](#grafana-dashboards)
  - [nginx](#nginx-tls-termination--reverse-proxy)
  - [Ingest](#ingest-from-remote-collectors)
- [Secrets](#secrets)
- [Dashboards](#dashboards)
  - [Sync](#sync)
  - [Agent Workflows](#agent-workflows)
- [Alerting](#alerting)
  - [Add a rule](#add-a-rule)
  - [Silence](#silence)
- [Profiling](#profiling)
  - [Query profiles from the CLI](#query-profiles-from-the-cli)
- [Future Work](#future-work)
- [Runbooks](RUNBOOKS.md)

## Requirements

- Single-node metrics storage + visualization; other hosts push to it
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
internet: users, remote collectors (vmagent + alloy, `collector.remote`)
    |
    v
nginx (443, TLS/ACME)
    |  ingest, write-only, basic auth (see Ingest):
    |    POST /o11y/metrics/api/v1/write
    |      -> victoriametrics /api/v1/write?extra_label=instance=<user>
    |    POST /o11y/profiles/push.v1.PusherService/Push -> pyroscope
    v
grafana (127.0.0.1:3000)
    | MetricsQL queries                 | profile queries
    v                                   v
victoriametrics (127.0.0.1:8428)    pyroscope (127.0.0.1:4040)
    ^ <-- vmalert rules,                ^ push, see Profiling
    |     see Alerting                  |
    | remote write                      alloy (127.0.0.1:12345, eBPF)
    | (/api/v1/write)
    |
vmagent (127.0.0.1:8429)
    | scrape (1m interval)
    +-- vmagent           localhost:8429/metrics
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

Server: `sauna` (Hetzner 6c/12t, 2x894 GiB NVMe RAID 0), also its own
collector (loopback).
Remote collectors: `phlipdesk` (desktop, behind NAT; no alerts).
DNS: `grafana.phlip9.com`, ingest on `sauna.phlip9.com`

## Files

| File | Purpose |
|------|---------|
| `nixos/mods/o11y/default.nix` | NixOS module: imports server + collector |
| `nixos/mods/o11y/server/default.nix` | Server: VM, blackbox probes |
| `nixos/mods/o11y/server/grafana.nix` | Server: Grafana, Git Sync, nginx vhost |
| `nixos/mods/o11y/server/alerting.nix` | Server: vmalert, Alertmanager, host ping |
| `nixos/mods/o11y/server/rules.nix` | Alert rules + inhibitions |
| `nixos/mods/o11y/server/alertmanager.tmpl` | Discord message templates |
| `nixos/mods/o11y/server/tests/rules.yml` | Rule unit tests (vmalert-tool) |
| `nixos/mods/o11y/server/pyroscope.nix` | Server: Pyroscope |
| `nixos/mods/o11y/server/ingest.nix` | Server: nginx ingest for remote collectors |
| `nixos/mods/o11y/collector/default.nix` | Collector: vmagent, node/nginx/postgres exporters |
| `nixos/mods/o11y/collector/lib.nix` | Scrape target helpers, ingest URL layout |
| `nixos/mods/o11y/collector/nixos-exporter.nix` | Collector: nixos-exporter |
| `nixos/mods/o11y/collector/alloy.nix` | Collector: Alloy eBPF profiler |
| `nixos/pkgs/grafana-alloy/` | Alloy (ahead of nixpkgs) |
| `nixos/pkgs/grafana-pyroscope-datasource/` | Grafana Pyroscope datasource |
| `nixos/tests/o11y.nix` | NixOS container test |
| `nixos/tests/o11y-alerting.nix` | NixOS container test: alert delivery |
| `nixos/tests/o11y-alerting-unit.nix` | Offline check: rules + routing |
| `nixos/tests/o11y-profiling.nix` | NixOS container test: Pyroscope |
| `nixos/tests/o11y-profiling-ebpf.nix` | NixOS VM test: Alloy eBPF end to end |
| `nixos/tests/o11y-ingest.nix` | NixOS container test: ingest + remote collector |
| `nixos/tests/lib/o11y-ingest.nix` | Test fixtures: self-signed cert, htpasswd |
| `nixos/sauna/default.nix` | NixOS machine config |
| `nixos/sauna/grafana/` | Dashboards (Git Sync manifests) |
| `.mcp.json` | `mcp-grafana` config for agents (points them at the skill) |
| `.agents/skills/grafana-dashboard/` | agent skill build/rework dashboards |
| `just/grafana-*.sh`, `just/grafana.jq`, `pkgs/grafana-screenshot/` | dashboard tools |

## Components

NixOS module `services.phlip9-o11y`. Roles:

- `server`: VictoriaMetrics, Grafana, vmalert + Alertmanager, Pyroscope,
  blackbox probes, ingest endpoint for remote collectors (`server.ingest`).
- `collector`: exporters, vmagent + scrape jobs (`collector.scrapeConfigs`),
  Alloy. Pushes to either server on same host (default: loopback + no auth), or
  `collector.remote` ingest endpoint over HTTPS w/ basic auth.

### vmagent (scraper)

`phlip9-o11y.collector.scrapeConfigs` -> remote-write ingest `/api/v1/write`

NixOS module: `services.vmagent`

- Listen: `127.0.0.1:8429` (`/metrics`, `/targets`)
- Best-effort delivery: in-memory queue capped at 100 blocks (~1 per
  non-empty 1s flush; time covered depends on load), no disk spool while
  running. While VM is down, scraping continues, until new samples are dropped
  (`vmagent_remotewrite_samples_dropped_total`). A clean stop writes the
  queue to disk and sends it after the restart.
- `remote`: basic auth, password via systemd credential.

### VictoriaMetrics (metrics storage)

Single-node binary that handles ingestion, storage, and querying.
Prometheus-compatible API.

NixOS module: `services.victoriametrics`

Config:
- `listenAddress`: `127.0.0.1:8428`
- `retentionPeriod`: `3` (3 months)
- Systemd hardening: DynamicUser, ProtectSystem, MemoryDeny, etc.

Storage sizing: with ~4 exporters at 15s scrape interval, expect
1-5 GiB/month. 3 months retention ≈ 5-15 GiB. The 1 TiB budget is
for long-term growth as we add more services and exporters.

Key endpoints:
- `/ping`: health check
- `/api/v1/query`: instant query (PromQL/MetricsQL)
- `/api/v1/query_range`: range query
- `/api/v1/write`: Prometheus remote write (via vmagent)
- `/metrics`: self-metrics
- `/vmui`: built-in query UI

### Grafana (dashboards)

NixOS module: `services.grafana`

Config:
- Listen: `127.0.0.1:3000`
- Database: sqlite3 (single user, no need for postgres)
- Provisioned datasources: VictoriaMetrics (default), Alertmanager, Pyroscope
- Sops secrets via `$__file{path}` provider
- Disable sign-up, disable gravatar, disable analytics

### nginx (TLS termination + reverse proxy)

- `grafana.phlip9.com` -> Grafana
- ingest locations on an existing HTTPS-only vhost, see below

### Ingest (from remote collectors)

`server.ingest = { enable; vhost; htpasswdFile; }` adds write-only
locations under `/o11y/` to an existing nginx vhost (`forceSSL` or
`onlySSL`). Remote collectors set `collector.remote.url =
"https://<vhost>/o11y"`. Enabled on `sauna.phlip9.com`; `phlipdesk` pushes
to it. To add a host, see [Add a collector host](RUNBOOKS.md#add-a-collector-host).

- `POST /o11y/metrics/api/v1/write` -> VictoriaMetrics
  `/api/v1/write?extra_label=instance=<username>`
- `POST /o11y/profiles/push.v1.PusherService/Push` -> Pyroscope (if
  `server.profiling.enable`)
- Auth: nginx basic auth (TODO(phlip9): mTLS)
- o11y server's own collector stays on loopback, w/o auth

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
| `o11y-ingest-htpasswd` | `nginx` | Ingest credentials, one line per collector host |
| `o11y-ingest-password` (collector hosts) | `vmagent`, `alloy` | That host's ingest password |

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
- Config: `services.phlip9-o11y.server.grafana.gitSync` in
  `nixos/sauna/default.nix`. `grafana-git-sync-setup.service` creates/updates
  the Grafana `Repository` resource, re-sends the PAT, and triggers a pull on
  every Grafana start (Grafana itself doesn't sync on startup). It also sets
  the org home dashboard (`gitSync.homeDashboard`): `overview`. A user's own
  home dashboard preference (Profile -> Preferences) overrides it.

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
- Alerts for root causes hide symptom alerts via inhibitions, per host.
- Host-level alerts only for `server.alerting.instances` (default: the
  server's hostname). Other hosts' series never fire or affect an alert.
- `HostNotReporting` pages when an alerted host's node-exporter `up` is
  missing for 3m (+2m): host down, or its vmagent dead.
- See alert history with `ALERTS{alertstate="firing"}` in Grafana. Active
  alerts + silences: Grafana > Alerting, `Alertmanager` datasource.

### Add a rule

1. Write the expr, run it live, and back-test it:

   ```bash
   $ curl -s --data-urlencode 'query=<expr>' http://127.0.0.1:8428/api/v1/query
   $ curl -s --data-urlencode 'query=count_over_time((<expr>)[90d:5m])' \
       http://127.0.0.1:8428/api/v1/query
   ```

2. Add it to a group in `nixos/mods/o11y/server/rules.nix`: `alert`,
   `expr`, `for`, `labels.severity`, and `annotations` w/ `summary` (what)
   and `description` (where to look). Other modules can append groups to
   `services.vmalert.instances."".rules.groups`.

3. `just alerting-test`: `vmalert -dryRun`, the unit tests, and `amtool`
   config + routing checks against sauna's rendered config. Non-obvious
   expr: add a case to `nixos/mods/o11y/server/tests/rules.yml`
   (annotations must match exactly). Routing or template changes: also
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
(127.0.0.1:4040, 30d retention), in one request per interval. Remote
collectors push through the ingest endpoint (HTTPS, basic auth). Grafana:
datasource `pyroscope`, Profiles Drilldown, `profiling` dashboard. Config:
`nixos/mods/o11y/server/pyroscope.nix`, `nixos/mods/o11y/collector/alloy.nix`.

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

For ad-hoc profiling, see our
[perf profiling skill](../../.agents/skills/perf-profile/SKILL.md).

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
  measured data; DWARF inline frames; app-side memory/mutex pprof.
