# Alerting for the phlip9-o11y metrics stack.
#
# Pipeline:
#
#   VictoriaMetrics --query--> vmalert --alerts--> Alertmanager --> Discord
#        ^                       |                      |
#        +--remoteWrite ALERTS---+                      +--> healthchecks.io
#
# - vmalert (127.0.0.1:8880) evaluates ./rules.nix against VM and writes
#   `ALERTS` series back into VM, so alert state survives restarts and shows
#   up in Grafana.
# - Alertmanager (127.0.0.1:9093) groups, inhibits, and routes alerts:
#   - `Watchdog` (always firing) -> healthchecks.io ping, never Discord. A
#     missed ping means some part of the pipeline (or the host) is dead.
#   - `severity=page` -> Discord, plus a short @mention message by day.
#   - everything else -> Discord, no mention.
# - Grafana gets an Alertmanager datasource (see ./default.nix) to browse
#   alerts and manage silences.
#
# Secrets (Discord webhook URL, healthchecks.io ping URLs, the Discord user
# id) never enter the nix store: URLs go through systemd LoadCredential and
# Alertmanager's `*_file` fields, the user id through `environmentFile`.
#
# See: doc/o11y/README.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.phlip9-o11y;
  cfgA = cfg.alerting;
  cfgVm = config.services.victoriametrics;
  cfgAm = config.services.prometheus.alertmanager;

  # Alert rule groups + Alertmanager inhibit rules
  alertRules = import ./rules.nix { inherit config lib; };

  vmalertAddr = "127.0.0.1:8880";
  amAddr = "${cfgAm.listenAddress}:${toString cfgAm.port}";

  # Alertmanager reads secrets from its systemd credentials directory.
  amCredsDir = "/run/credentials/alertmanager.service";

  # Grafana base URL for links in ./alertmanager.tmpl
  grafanaUrlTmpl = pkgs.writeText "grafana-url.tmpl" ''
    {{ define "grafana.url" }}https://${cfg.grafana.domain}{{ end }}
  '';

  # Quiet hours: 23:00-09:00 America/Los_Angeles. Pages arrive w/o an
  # @mention. Alertmanager rejects ranges that wrap around midnight.
  night = {
    name = "night";
    time_intervals = [
      {
        times = [
          {
            start_time = "23:00";
            end_time = "24:00";
          }
          {
            start_time = "00:00";
            end_time = "09:00";
          }
        ];
        location = "America/Los_Angeles";
      }
    ];
  };

  amConfig = {
    templates = [
      "${./alertmanager.tmpl}"
      "${grafanaUrlTmpl}"
    ];

    route = {
      receiver = "discord-quiet";
      group_by = [
        "severity"
        "alertname"
      ];
      group_wait = cfgA.groupWait;
      group_interval = cfgA.groupInterval;
      repeat_interval = "12h";

      routes = [
        # Heartbeat (see ./rules.nix): ping every ~2 min while healthy.
        # healthchecks.io expects one ping per 5 min (+ 5 min grace).
        {
          matchers = [ ''alertname="Watchdog"'' ];
          receiver = "healthchecks-watchdog";
          group_by = [ "alertname" ];
          group_wait = "0s";
          group_interval = "1m";
          repeat_interval = "2m";
        }
        # Pages, day + night: the full message and its resolve. One
        # always-active receiver owns them: Alertmanager's notification log
        # is per receiver, and a receiver only sends a resolve for a firing
        # it sent. A time-gated receiver would drop resolves at the edges.
        {
          matchers = [ ''severity="page"'' ];
          receiver = "discord-quiet";
          repeat_interval = "1h";
          continue = true;
        }
        # Pages by day: an extra, short message w/ the @mention. Never a
        # resolve. Muted at night: a page still firing at 09:00 gets its
        # mention at the next group flush, since a muted flush logs nothing
        # (or the last mention is older than `repeat_interval`).
        {
          matchers = [ ''severity="page"'' ];
          receiver = "discord-page";
          mute_time_intervals = [ "night" ];
          repeat_interval = "1h";
        }
      ];
    };

    receivers = [
      {
        name = "discord-page";
        discord_configs = [
          {
            webhook_url_file = "${amCredsDir}/discord-webhook-url";
            # envsubst fills in `$DISCORD_USER_ID` from `environmentFile`
            # before Alertmanager parses the config.
            content = "<@$DISCORD_USER_ID>";
            title = ''{{ template "discord.phlip9.title" . }}'';
            message = ''{{ template "discord.phlip9.mention" . }}'';
            # discord-quiet sends the resolve.
            send_resolved = false;
          }
        ];
      }
      {
        name = "discord-quiet";
        discord_configs = [
          {
            webhook_url_file = "${amCredsDir}/discord-webhook-url";
            title = ''{{ template "discord.phlip9.title" . }}'';
            message = ''{{ template "discord.phlip9.message" . }}'';
            send_resolved = true;
          }
        ];
      }
      {
        name = "healthchecks-watchdog";
        webhook_configs = [
          {
            url_file = "${amCredsDir}/healthchecks-watchdog-ping-url";
            send_resolved = false;
            max_alerts = 1;
          }
        ];
      }
    ];

    inhibit_rules = alertRules.inhibitRules;
    time_intervals = [ night ];
  };
in
{
  options.services.phlip9-o11y.alerting = {
    enable = lib.mkEnableOption "alerting (vmalert + Alertmanager)";

    discordWebhookUrlFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the Discord webhook URL for `#alerts`.
        In production, use config.sops.secrets.*.path.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to an Alertmanager EnvironmentFile w/ `DISCORD_USER_ID=<n>`, the
        Discord user that daytime pages @mention. Alertmanager's config gets
        envsubst'ed w/ it at start.
        In production, use config.sops.secrets.*.path.
      '';
    };

    healthchecksWatchdogPingUrlFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the healthchecks.io ping URL that the
        always-firing `Watchdog` alert pings via Alertmanager.
        In production, use config.sops.secrets.*.path.
      '';
    };

    groupWait = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        Test knob. How long Alertmanager buffers a new alert group before
        the first notification.
      '';
    };

    groupInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = ''
        Test knob. How long Alertmanager waits before notifying about
        changes (new or resolved alerts) in an existing group.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfgA.enable) {
    # ===================================================================
    # vmalert - rule evaluation
    # ===================================================================
    services.vmalert.instances."" = {
      enable = true;
      settings = {
        httpListenAddr = vmalertAddr;
        "datasource.url" = "http://${cfgVm.listenAddress}";
        # Write `ALERTS` + `ALERTS_FOR_STATE` series to VM ...
        "remoteWrite.url" = "http://${cfgVm.listenAddress}";
        # ... and restore pending `for` state from them on restart.
        "remoteRead.url" = "http://${cfgVm.listenAddress}";
        "notifier.url" = [ "http://${amAddr}" ];
        evaluationInterval = lib.mkDefault "1m";
        # Base of each alert's source link (`generatorURL`, Grafana's "See
        # source"): `<external.url>/vmalert/alert?...` on vmalert's own UI.
        # Works through the tunnel `ssh -L 8880:127.0.0.1:8880 sauna`.
        "external.url" = "http://localhost:8880";
      };
      # Other modules can append their own groups.
      rules.groups = alertRules.groups;
    };

    systemd.services.vmalert = {
      wants = [ "victoriametrics.service" ];
      after = [ "victoriametrics.service" ];

      # Hardening. Only talks to VM + Alertmanager on loopback.
      serviceConfig = {
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    # ===================================================================
    # Alertmanager - grouping, inhibition, routing, delivery
    # ===================================================================
    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9093;
      # Single node: no gossip listener on 0.0.0.0:9094.
      extraFlags = [ "--cluster.listen-address=" ];
      # The module envsubst's the whole config, so it must not contain a
      # literal `$` other than `$DISCORD_USER_ID`. All Go templates that
      # need `$` live in ./alertmanager.tmpl, which is not substituted.
      environmentFile = cfgA.environmentFile;
      configuration = amConfig;
    };

    systemd.services.alertmanager.serviceConfig.LoadCredential = [
      "discord-webhook-url:${cfgA.discordWebhookUrlFile}"
      "healthchecks-watchdog-ping-url:${cfgA.healthchecksWatchdogPingUrlFile}"
    ];

    assertions = [
      {
        # Notifications link to Grafana.
        assertion = cfg.grafana.domain != null;
        message = "phlip9-o11y: alerting needs grafana.domain";
      }
      {
        # envsubst would eat any other `$`, ex: a `$labels` template.
        # (`templates` are store paths.)
        assertion =
          let
            json = builtins.toJSON (removeAttrs amConfig [ "templates" ]);
            rest = lib.replaceStrings [ "$DISCORD_USER_ID" ] [ "" ] json;
          in
          !(lib.hasInfix "$" rest);
        message = ''
          phlip9-o11y: the Alertmanager config may only contain `$` in
          `$DISCORD_USER_ID`. Move Go templates into alertmanager.tmpl.
        '';
      }
    ];
  };
}
