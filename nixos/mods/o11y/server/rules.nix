# Alert rules + inhibitions for sauna's hosts and services. Just data that
# ./alerting.nix imports and wires into vmalert and Alertmanager.
#
# Severity:
# - `page`: wake me up (@mention by day). Box full, wedged, or losing data.
# - `warn`: look today.
# - `info`: context, ex: for a later page or a morning glance.
#
# Each rule: `for` long enough to ride out deploy restarts (scrapes run every
# 1m), `summary` says what, `description` says where to look. Thresholds
# were back-tested over 90d of sauna data.
#
# Host scoping: only hosts in `server.alerting.instances` get alerts. Every
# selector on series a collector scrapes (exporters, Alloy, `up`) carries
# the `inst` matcher. Aggregates over these series are `by (instance)`.
#
# Not scoped: server-only self metrics (vmalert, Alertmanager, Grafana) and
# blackbox probes, which are labeled `instance=<url>`.
#
# Keep in sync: nixos/sauna/grafana/overview.json mirrors some rules in its
# tiles, thresholds, and descriptions; each such rule says so. Its alert
# table, counts, and annotations use the `severity` values above.
#
# Unit tests: ./tests/rules.yml
{
  config,
  lib,
}:

let
  cfg = config.services.phlip9-o11y.server;
  cfgExporters = config.services.prometheus.exporters;
  cfgRbitcoin = config.services.rbitcoin;

  # Hosts that get host-level alerts, see `server.alerting.instances`. Their
  # names are plain `[A-Za-z0-9_-]+` (option type): no regex escaping.
  alertedInstances = cfg.alerting.instances;
  instRegex = lib.concatStringsSep "|" alertedInstances;
  # Label matcher for alerted hosts' series. Goes into every selector of a
  # collector's series: `node_load5{${inst}}`, `up{job="x", ${inst}}`.
  # Also an Alertmanager matcher.
  inst = ''instance=~"${instRegex}"'';
  # Alertmanager matcher for alerts that aren't about an alerted host: no
  # `instance` label (aggregates), or a probe URL.
  notInst = ''instance!~"${instRegex}"'';

  # Units that must stay active. `github-agent-authd.service` is socket
  # activated and idles inactive, so watch its socket. Units that don't
  # exist on a host have no series and never fire.
  #
  # Keep in sync: nixos/sauna/grafana/overview.json "Services" tiles +
  # "Status timeline" check most of these units by name, plus
  # paseo-relay, vmagent, vmalert, alertmanager, alloy, pyroscope,
  # nix-daemon.socket. As w/ these rules, a unit missing on a host hides
  # its checks there (incl. its service's scrapes + probes).
  watchedUnits = [
    "github-agent-authd.socket"
    "github-webhook.service"
    "grafana.service"
    "nginx.service"
    "niks3.service"
    "nixbot.service"
    "paseo.service"
    "postgresql.service"
    "sshd.service"
    "systemd-oomd.service"
    "victoriametrics.service"
  ];

  # `alertname=~"a|b|c"` matcher
  alertnameIn = names: ''alertname=~"${lib.concatStringsSep "|" names}"'';

  # Always-firing heartbeat. Alertmanager routes it only to healthchecks.io,
  # which alerts (off-box) when the pings stop. Keep in sync:
  # nixos/sauna/grafana/overview.json uses it as the alert feed heartbeat
  # (alerting tile, Host health counts, alert tables) and hides it by name.
  watchdogGroup = {
    name = "watchdog";
    rules = [
      {
        alert = "Watchdog";
        expr = "vector(1)";
        labels.severity = "none";
        annotations = {
          summary = "Alerting pipeline heartbeat, always firing";
          description = "Pings healthchecks.io check sauna-watchdog.";
        };
      }
    ];
  };

  # Scrape targets.
  targetsGroup = {
    name = "targets";
    rules = [
      # rbitcoin restarts slowly, see its own group. Blackbox's `up` is
      # labeled w/ the probe URL, like its probes: not host-scoped. Keep in
      # sync: nixos/sauna/grafana/overview.json "Failed scrapes" description
      # (5m).
      {
        alert = "TargetDown";
        expr = lib.concatStringsSep " " [
          ''up{job!~"rbitcoin|blackbox", ${inst}} == 0''
          ''or up{job="blackbox"} == 0''
        ];
        for = "5m";
        labels.severity = "warn";
        annotations = {
          summary = "{{ $labels.job }} scrape failing";
          description = "Service down or wedged? journalctl -u <its unit>";
        };
      }
      # vmagent writes no stale markers when it stops (or the host dies),
      # and a dead scraper writes no `up == 0`; the host's series just stop,
      # so TargetDown can't see it.
      #
      # Fires per alerted host w/o a single node-exporter `up` sample (0 or 1)
      # for 3m, + 2m `for`. Deploys restart vmagent in seconds (<= 1 missed 1m
      # scrape); at boot, `for` covers the time to vmagent's first scrape.
      #
      # Never fires for a host that isn't in `alerting.instances`. Nothing to
      # inhibit: the host's other alerts have no data while it fires.
      {
        alert = "HostNotReporting";
        expr = lib.concatMapStringsSep " or " (
          host: ''absent_over_time(up{job="node-exporter", instance="${host}"}[3m])''
        ) alertedInstances;
        for = "2m";
        labels.severity = "page";
        annotations = {
          summary = "{{ $labels.instance }} stopped reporting metrics";
          description = lib.concatStringsSep " " [
            "Host down, or vmagent / node-exporter dead?"
            "systemctl status vmagent prometheus-node-exporter"
          ];
        };
      }
    ];
  };

  # CPU, memory, clock.
  hostGroup = {
    name = "host";
    rules = [
      # Inhibits restart noise for 15m, see `inhibitRules`.
      #
      # Fires for 15m once nixos-exporter's boot count exceeds its last value
      # from >= 15m ago, looking back up to a day: a reboot gap (+ its stale
      # marker) doesn't hide the old value. Clock-independent, unlike
      # `node_boot_time_seconds`. A new series (first install, relabel) has
      # no old value, so no false reboot, unlike `delta`/`increase`.
      {
        alert = "HostRebooted";
        expr = lib.concatStringsSep " " [
          "nixos_boots_total{${inst}}"
          "> last_over_time(nixos_boots_total{${inst}}[1d] offset 15m)"
        ];
        labels.severity = "info";
        annotations = {
          summary = "{{ $labels.instance }} rebooted (boot {{ $value }})";
          description = "Expected after a deploy w/ a new kernel; else why?";
        };
      }
      # `for` is short on purpose: on 2026-10-29 available memory went
      # 85% -> 2% in 6 min, then the box froze.
      {
        alert = "MemLow";
        expr = lib.concatStringsSep " " [
          "node_memory_MemAvailable_bytes{${inst}}"
          "/ node_memory_MemTotal_bytes{${inst}} < 0.10"
        ];
        for = "1m";
        labels.severity = "page";
        annotations = {
          summary = "Memory available {{ $value | humanizePercentage }}";
          description = "Find the hog: systemd-cgtop -m";
        };
      }
      # systemd-oomd kills don't count, only the kernel OOM killer.
      {
        alert = "OOMKill";
        expr = "increase(node_vmstat_oom_kill{${inst}}[15m]) > 0";
        labels.severity = "warn";
        annotations = {
          summary = "Kernel OOM killer ran";
          description = "journalctl -k -g 'Out of memory'";
        };
      }
      # CI saturating the CPU is by design; only long stretches count.
      # Per host: its load / its CPU threads (1 `idle` series each).
      {
        alert = "LoadHigh";
        expr = lib.concatStringsSep " " [
          "node_load5{${inst}}"
          "/ on (instance) group_left ()"
          ''count by (instance) (node_cpu_seconds_total{mode="idle", ${inst}})''
          "> 2"
        ];
        for = "30m";
        labels.severity = "info";
        annotations = {
          summary = "load5 at {{ $value | humanize }}x the CPU threads";
          description = "Runaway CI build or agent? systemd-cgtop";
        };
      }
      # Keep in sync: nixos/sauna/grafana/overview.json "Host health" clock
      # tile (same checks).
      {
        alert = "ClockBad";
        expr = lib.concatStringsSep " " [
          "abs(node_timex_offset_seconds{${inst}}) > 0.1"
          "or node_timex_sync_status{${inst}} == 0"
        ];
        for = "15m";
        labels.severity = "warn";
        annotations = {
          summary = "Clock unsynced or off by >100ms";
          description = "timedatectl timesync-status";
        };
      }
    ];
  };

  # `/` is ext4 on md127 (RAID0 over 2 NVMe), and holds the nix store,
  # VictoriaMetrics, and postgres. `/boot` is the ESP.
  storageGroup = {
    name = "storage";
    rules = [
      {
        alert = "RootDiskFull";
        expr = lib.concatStringsSep " " [
          ''node_filesystem_avail_bytes{mountpoint="/", ${inst}}''
          ''/ node_filesystem_size_bytes{mountpoint="/", ${inst}} < 0.05''
        ];
        for = "5m";
        labels.severity = "page";
        annotations = {
          summary = "/ has {{ $value | humanizePercentage }} free";
          description = "nix-collect-garbage; prune agent worktrees.";
        };
      }
      {
        alert = "RootDiskLow";
        expr = lib.concatStringsSep " " [
          ''node_filesystem_avail_bytes{mountpoint="/", ${inst}}''
          ''/ node_filesystem_size_bytes{mountpoint="/", ${inst}} < 0.15''
        ];
        for = "15m";
        labels.severity = "warn";
        annotations = {
          summary = "/ has {{ $value | humanizePercentage }} free";
          description = "nix-collect-garbage; prune agent worktrees.";
        };
      }
      # 6h trend smooths out CI build churn.
      {
        alert = "RootDiskFill24h";
        expr = lib.concatStrings [
          "predict_linear(node_filesystem_avail_bytes"
          ''{mountpoint="/", ${inst}}[6h], 24*3600) < 0''
        ];
        for = "30m";
        labels.severity = "warn";
        annotations = {
          summary = "/ fills up within 24h at the 6h trend";
          description = "Who's writing? du -xsh /var/lib/*";
        };
      }
      # A full ESP breaks `nixos-rebuild switch`.
      {
        alert = "BootLow";
        expr = lib.concatStringsSep " " [
          ''node_filesystem_avail_bytes{mountpoint="/boot", ${inst}}''
          "< 200e6"
        ];
        for = "10m";
        labels.severity = "warn";
        annotations = {
          summary = "/boot has {{ $value | humanize1024 }}B free";
          description = "Delete old generations, then switch again.";
        };
      }
      {
        alert = "InodesLow";
        expr = lib.concatStringsSep " " [
          ''node_filesystem_files_free{mountpoint="/", ${inst}}''
          ''/ node_filesystem_files{mountpoint="/", ${inst}} < 0.10''
        ];
        for = "15m";
        labels.severity = "warn";
        annotations = {
          summary = "/ has {{ $value | humanizePercentage }} inodes free";
          description = "Many small files: nix store, CI checkouts.";
        };
      }
      # ext4 remounts read-only on errors.
      {
        alert = "FsBroken";
        expr = lib.concatStringsSep " " [
          ''node_filesystem_readonly{mountpoint=~"/|/boot", ${inst}} == 1''
          ''or node_filesystem_device_error{mountpoint=~"/|/boot", ${inst}}''
          "== 1"
        ];
        for = "1m";
        labels.severity = "page";
        annotations = {
          summary = "{{ $labels.mountpoint }} read-only or erroring";
          description = "journalctl -k -g 'EXT4-fs error|I/O error'";
        };
      }
      # RAID0: one lost member loses the array, so this fires late.
      # Keep in sync: nixos/sauna/grafana/overview.json "Host health" RAID
      # tile (same checks; hidden on hosts w/o the mdadm collector).
      {
        alert = "MdFailed";
        expr = lib.concatStringsSep " " [
          ''node_md_disks{state="failed", ${inst}} > 0''
          ''or node_md_state{state="inactive", ${inst}} == 1''
        ];
        for = "2m";
        labels.severity = "page";
        annotations = {
          summary = "{{ $labels.device }} has a failed or inactive member";
          description = "cat /proc/mdstat. Ask Hetzner for a disk swap.";
        };
      }
    ];
  };

  # Unit + timer state from node-exporter's systemd collector.
  systemdGroup = {
    name = "systemd";
    rules = [
      # Failed oneshots (nix-gc, acme-order-renew-*, niks3-gc) stay failed
      # until their next success.
      {
        alert = "UnitFailed";
        expr = ''node_systemd_unit_state{state="failed", ${inst}} == 1'';
        for = "2m";
        labels.severity = "warn";
        annotations = {
          summary = "{{ $labels.name }} failed";
          description = "systemctl status {{ $labels.name }}";
        };
      }
      {
        alert = "UnitNotActive";
        expr = lib.concatStrings [
          ''node_systemd_unit_state{state="active", ${inst}, name=~"''
          (lib.concatStringsSep "|" watchedUnits)
          ''"} == 0''
        ];
        for = "5m";
        labels.severity = "warn";
        annotations = {
          summary = "{{ $labels.name }} not active";
          description = "systemctl status {{ $labels.name }}";
        };
      }
      # Timers that never ran report 0, skip them. acme timers have a
      # randomized delay; renewals start 30d out.
      {
        alert = "TimerStale";
        expr =
          let
            last = "node_systemd_timer_last_trigger_seconds";
            age = timers: ''time() - (${last}{name=~"${timers}", ${inst}} > 0)'';
          in
          lib.concatStringsSep " or " [
            "(${age "niks3-gc.timer|nix-optimise.timer"} > 36*3600)"
            "(${age "acme-renew-.*.timer"} > 4*86400)"
            "(${age "nix-gc.timer|fstrim.timer"} > 8*86400)"
          ];
        labels.severity = "warn";
        annotations = {
          summary = lib.concatStrings [
            "{{ $labels.name }} last ran"
            " {{ $value | humanizeDuration }} ago"
          ];
          description = "systemctl list-timers; journalctl -u <its service>";
        };
      }
    ];
  };

  # vmalert + Alertmanager self-health. A dead pipeline can't report itself;
  # the healthchecks.io checks cover that. These catch partial failures.
  alertingGroup = {
    name = "alerting";
    rules = [
      {
        alert = "VmalertConfigReloadFailed";
        expr = "vmalert_config_last_reload_successful != 1";
        labels.severity = "warn";
        annotations = {
          summary = "vmalert rejected its new rules, still runs the old ones";
          description = "journalctl -u vmalert";
        };
      }
      {
        alert = "VmalertRuleErrors";
        expr = lib.concatStringsSep " " [
          "sum by (group)"
          "(increase(vmalert_alerting_rules_errors_total[5m])) > 0"
        ];
        for = "5m";
        labels.severity = "warn";
        annotations = {
          summary = "Rules in group {{ $labels.group }} fail to evaluate";
          description = "Bad query or VictoriaMetrics trouble. vmalert UI.";
        };
      }
      {
        alert = "VmalertNotifyErrors";
        expr = "increase(vmalert_alerts_send_errors_total[5m]) > 0";
        for = "15m";
        labels.severity = "warn";
        annotations = {
          summary = "vmalert can't send alerts to Alertmanager";
          description = "journalctl -u vmalert -u alertmanager";
        };
      }
      {
        alert = "AlertmanagerConfigReloadFailed";
        expr = "alertmanager_config_last_reload_successful != 1";
        labels.severity = "warn";
        annotations = {
          summary = "Alertmanager rejected its config, still runs the old one";
          description = "journalctl -u alertmanager";
        };
      }
      # If Discord fails, this alert can't reach Discord either: check
      # Grafana. healthchecks.io only notices if the Watchdog pings fail too.
      {
        alert = "AlertmanagerNotifyFailed";
        expr = lib.concatStringsSep " " [
          "sum by (integration)"
          "(increase(alertmanager_notifications_failed_total[15m])) > 0"
        ];
        labels.severity = "warn";
        annotations = {
          summary = "Alertmanager {{ $labels.integration }} deliveries fail";
          description = "Rotated webhook/ping URL? journalctl -u alertmanager";
        };
      }
    ];
  };

  # Grafana Git Sync: dashboards <-> phlip9/dotfiles.
  grafanaGroup = {
    name = "grafana";
    rules = [
      # Health checks run ~10/h. Keep in sync:
      # nixos/sauna/grafana/overview.json "Services" grafana tile + "Status
      # timeline" (>= 2 failed checks in 15m).
      {
        alert = "GrafanaSyncUnhealthy";
        expr = lib.concatStrings [
          "sum(increase(grafana_provisioning_health_checked_total"
          ''{resource="repository", outcome!="success"}[15m])) >= 2''
        ];
        labels.severity = "warn";
        annotations = {
          summary = "Grafana Git Sync repository unhealthy";
          description = lib.concatStringsSep " " [
            "GitHub PAT `grafana-git-sync-token` expired? See"
            "doc/o11y/RUNBOOKS.md \"Git Sync setup\"."
          ];
        };
      }
      # No health checks: controller stuck, or no Repository resource.
      # Grafana creates the check counter on the first check, so a
      # controller stuck since startup has no series: count that as 0, if
      # Grafana is up and reports a Repository.
      {
        alert = "GrafanaSyncStalled";
        expr = lib.concatStrings [
          "((sum(increase(grafana_provisioning_health_checked_total"
          ''{resource="repository"}[2h])) or vector(0)) < 1''
          " and on() grafana_stat_totals_repositories >= 1)"
          " or grafana_stat_totals_repositories < 1"
        ];
        for = "30m";
        labels.severity = "warn";
        annotations = {
          summary = "Grafana Git Sync stopped checking its repository";
          description = "systemctl restart grafana-git-sync-setup";
        };
      }
    ];
  };

  # postgres, used by nixbot + niks3.
  postgresGroup = {
    name = "postgres";
    rules = [
      # Also catches exporter query errors.
      {
        alert = "PgDown";
        expr = lib.concatStringsSep " " [
          "pg_up{${inst}} == 0"
          "or pg_exporter_last_scrape_error{${inst}} > 0"
        ];
        for = "2m";
        labels.severity = "warn";
        annotations = {
          summary = "postgres down or its exporter can't query it";
          description = "journalctl -u postgresql";
        };
      }
      # Leave room for the reserved superuser connections.
      {
        alert = "PgConnections";
        expr = lib.concatStringsSep " " [
          "sum by (instance) (pg_stat_activity_count{${inst}})"
          "/ (max by (instance) (pg_settings_max_connections{${inst}})"
          "- max by (instance)"
          "(pg_settings_superuser_reserved_connections{${inst}}))"
          "> 0.8"
        ];
        for = "5m";
        labels.severity = "warn";
        annotations = {
          summary = "postgres at {{ $value | humanizePercentage }} of conns";
          description = "Connection leak? select * from pg_stat_activity";
        };
      }
      {
        alert = "PgLongTx";
        expr = lib.concatStrings [
          "max by (instance, datname) (pg_stat_activity_max_tx_duration"
          ''{datname!~"template.*", state=~"active|idle in transaction.*",''
          " ${inst}})"
          " > 600"
        ];
        for = "5m";
        labels.severity = "warn";
        annotations = {
          summary = lib.concatStrings [
            "{{ $labels.datname }} transaction open"
            " for {{ $value | humanizeDuration }}"
          ];
          description = "Blocks vacuum. select * from pg_stat_activity";
        };
      }
    ];
  };

  # HTTPS probes of `phlip9-o11y.server.probes` through blackbox_exporter.
  probesGroup = {
    name = "probes";
    rules = [
      {
        alert = "ProbeFailed";
        expr = ''probe_success{job="blackbox"} == 0'';
        for = "5m";
        labels.severity = "warn";
        annotations = {
          summary = "{{ $labels.instance }} unreachable from sauna";
          description = "No 2xx w/ valid cert. curl -v {{ $labels.instance }}";
        };
      }
      # ACME renews 30d out, so <3d left = renewals failing for 4 weeks.
      # Once expired, TLS verification fails and the probe stops reporting
      # expiry, so ProbeFailed takes over. Keep in sync:
      # nixos/sauna/grafana/overview.json "Min cert validity" (red < 3d,
      # description).
      {
        alert = "CertExpiry";
        expr = lib.concatStringsSep " " [
          ''probe_ssl_earliest_cert_expiry{job="blackbox"} - time()''
          "< 3*86400"
        ];
        labels.severity = "page";
        annotations = {
          summary = lib.concatStrings [
            "{{ $labels.instance }} cert expires"
            " in {{ $value | humanizeDuration }}"
          ];
          description = "ACME renewal failing. journalctl -u 'acme-*'";
        };
      }
    ];
  };

  # nginx stub_status. No per-vhost status codes, see blackbox probes.
  nginxGroup = {
    name = "nginx";
    rules = [
      {
        alert = "NginxDown";
        expr = "nginx_up{${inst}} == 0";
        for = "3m";
        labels.severity = "warn";
        annotations = {
          summary = "nginx stub_status unreachable";
          description = "systemctl status nginx; nginx -t";
        };
      }
    ];
  };

  # nixbot CI.
  nixbotGroup = {
    name = "nixbot";
    rules = [
      # The series exists only while the queue is non-empty.
      {
        alert = "NixbotWorkStuck";
        expr = lib.concatStringsSep " " [
          "max by (instance)"
          "(nixbot_work_queue_oldest_age_seconds{${inst}}) > 1800"
        ];
        for = "10m";
        labels.severity = "warn";
        annotations = {
          summary = "nixbot work pending for {{ $value | humanizeDuration }}";
          description = "Dispatcher stuck? journalctl -u nixbot";
        };
      }
      # Uploads go through niks3 to R2. Keep in sync:
      # nixos/sauna/grafana/overview.json "Cache upload backlog" description
      # (30m, 15m).
      {
        alert = "NixbotUploadStuck";
        expr = lib.concatStringsSep " " [
          "max by (instance)"
          "(nixbot_upload_queue_oldest_age_seconds{${inst}}) > 1800"
          "or sum by (instance) (nixbot_upload_queue_retrying{${inst}}) > 0"
        ];
        for = "15m";
        labels.severity = "warn";
        annotations = {
          summary = "nixbot cache uploads stuck or retrying";
          description = "niks3 or R2 trouble? journalctl -u niks3 -u nixbot";
        };
      }
      # `nixbot_builds{status}` is a gauge, the build rows per status, and
      # retention cleanup shrinks it. Clamp each 1h delta at 0, so a
      # cleanup counts as no new builds. Usually code, not infra.
      {
        alert = "NixbotBuildFailures";
        expr =
          let
            builds =
              status:
              lib.concatStrings [
                "sum by (instance) (clamp_min(delta("
                ''nixbot_builds{status=~"${status}", ${inst}}[1h]), 0))''
              ];
            failed = builds "failed";
          in
          "${failed} >= 3 and ${failed} / ${builds "succeeded|failed"} > 0.5";
        labels.severity = "info";
        annotations = {
          summary = "Most nixbot builds failed in the last hour";
          description = "https://ci.phlip9.com";
        };
      }
    ];
  };

  # Continuous profiling: Alloy eBPF collector -> Pyroscope. TargetDown
  # covers either one down. Profiles are best-effort, so nothing pages.
  profilingGroup = {
    name = "profiling";
    rules = [
      # Profiles lost: pushes that failed after all retries (Pyroscope down
      # or rejecting), or profiles that missed their push deadline (one
      # collect interval). Drops must keep happening for 15m (short window
      # + `for`), so one-off bursts don't fire, ex: a big nix build. The
      # write counter only exists after its first drop. Keep in sync:
      # nixos/sauna/grafana/overview.json "Profiles dropped" (same metrics).
      {
        alert = "ProfilesDropped";
        expr = lib.concatStrings [
          "sum by (instance) (increase({__name__=~"
          ''"pyroscope_write_dropped_profiles_total''
          ''|pyroscope_ebpf_pprofs_dropped_total", ${inst}}[5m])) > 0''
        ];
        for = "15m";
        labels.severity = "warn";
        annotations = {
          summary = "Alloy dropped {{ $value | humanize }} profiles in 5m";
          description = "journalctl -u alloy -u pyroscope";
        };
      }
      # Ex: the eBPF profiler failed to load (missing cap, kernel change).
      # A silently broken profiler (`[unknown]` frames) doesn't show here.
      {
        alert = "AlloyUnhealthy";
        expr = lib.concatStrings [
          "sum by (instance) (alloy_component_controller_running_components"
          ''{health_type!="healthy", ${inst}}) > 0''
        ];
        for = "10m";
        labels.severity = "warn";
        annotations = {
          summary = "{{ $value }} Alloy components not healthy";
          description = lib.concatStringsSep " " [
            "journalctl -u alloy;"
            "curl 127.0.0.1:12345/api/v0/web/components"
          ];
        };
      }
      # Retention is time-based only, no size cap. From the pyroscope-du
      # timer (./pyroscope.nix).
      {
        alert = "PyroscopeDiskHigh";
        # A runaway guard, far above normal use: ~80 MB/day on sauna
        # (2026-11), so ~2.5 GB at 30d retention, plus remote hosts.
        expr = "pyroscope_data_bytes{${inst}} > 50e9";
        for = "1h";
        labels.severity = "warn";
        annotations = {
          summary = "Pyroscope uses {{ $value | humanize1024 }}B on disk";
          description = "Lower server.profiling.retentionPeriod or collector.profiling.sampleRate.";
        };
      }
    ];
  };

  # rbitcoin node. Thresholds assume mainnet.
  rbitcoinGroup = {
    name = "rbitcoin";
    rules = [
      # TargetDown for rbitcoin: slow starts, so a longer `for`.
      {
        alert = "RbitcoinDown";
        expr = ''up{job="rbitcoin", ${inst}} == 0'';
        for = "10m";
        labels.severity = "warn";
        annotations = {
          summary = "rbitcoin /metrics unreachable";
          description = "journalctl -u rbitcoin";
        };
      }
      # P(no block in 2h) on mainnet is ~6e-6.
      {
        alert = "RbitcoinTipStale";
        expr = lib.concatStringsSep " " [
          "rbitcoin_tip_age_seconds{${inst}} > 7200"
          "and rbitcoin_initial_block_download{${inst}} == 0"
        ];
        for = "10m";
        labels.severity = "warn";
        annotations = {
          summary = "rbitcoin tip is {{ $value | humanizeDuration }} old";
          description = "Stalled sync or no peers?";
        };
      }
      {
        alert = "RbitcoinPeers";
        expr = lib.concatStringsSep " " [
          "sum by (instance)"
          ''(rbitcoin_connections{direction="out", ${inst}}) < 3''
        ];
        for = "10m";
        labels.severity = "warn";
        annotations = {
          summary = "rbitcoin has {{ $value }} outbound peers";
          description = "Network trouble? Eclipse risk.";
        };
      }
    ];
  };
in
{
  # vmalert rule groups
  groups = [
    watchdogGroup
    targetsGroup
    hostGroup
    storageGroup
    systemdGroup
    alertingGroup
  ]
  ++ lib.optional (cfg.probes != [ ]) probesGroup
  ++ lib.optional cfg.grafana.gitSync.enable grafanaGroup
  ++ lib.optional cfgExporters.postgres.enable postgresGroup
  ++ lib.optional cfgExporters.nginx.enable nginxGroup
  ++ lib.optional config.services.nixbot.enable nixbotGroup
  ++ lib.optional cfg.profiling.enable profilingGroup
  ++ lib.optional (cfgRbitcoin.enable && cfgRbitcoin.metrics) rbitcoinGroup;

  # Alertmanager `inhibit_rules`. While a source alert fires, matching target
  # alerts are not sent.
  #
  # Every source is a host alert w/ `instance=<host>`. Targets are either:
  # - host alerts (`instance=<host>`, incl. per-host service aggregates):
  #   only muted by the same host's source, `equal = [ "instance" ]`.
  #   Alertmanager compares a label missing on one side as "", so this
  #   rule never matches the targets below.
  # - server-level alerts: no `instance` (vmalert, Alertmanager, Grafana
  #   aggregates) or a probe URL. Only muted by a source on the server's
  #   own host: they're about its services, which its trouble explains.
  inhibitRules =
    let
      serverInst = ''instance="${config.networking.hostName}"'';
      inhibit =
        {
          source_matchers,
          target_matchers,
        }:
        [
          {
            inherit source_matchers target_matchers;
            equal = [ "instance" ];
          }
          {
            source_matchers = source_matchers ++ [ serverInst ];
            target_matchers = target_matchers ++ [ notInst ];
          }
        ];
    in
    # If the box is fucked only alert the cause
    inhibit {
      source_matchers = [
        (alertnameIn [
          "MemLow"
          "RootDiskFull"
          "FsBroken"
        ])
      ];
      target_matchers = [ ''severity="warn"'' ];
    }
    # After boot (15m) let things settle out a bit
    ++ inhibit {
      source_matchers = [ ''alertname="HostRebooted"'' ];
      target_matchers = [
        (alertnameIn [
          "TargetDown"
          "UnitNotActive"
          "Nixbot.+"
        ])
      ];
    }
    ++ [
      # nixbot keeps its state in Postgres, on the same host
      {
        source_matchers = [ ''alertname="PgDown"'' ];
        target_matchers = [ ''alertname=~"Nixbot.+"'' ];
        equal = [ "instance" ];
      }
    ];
}
