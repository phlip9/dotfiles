# o11y server: alerting for the metrics stack.
#
# Pipeline:
#
#   VictoriaMetrics --query--> vmalert --alerts--> Alertmanager --> Discord
#        ^                       |                      |
#        +--remoteWrite ALERTS---+                      +--> healthchecks.io
#
# - vmalert evaluates ./rules.nix and persists `ALERTS` series in VM
# - Alertmanager routes `Watchdog` -> healthchecks.io, pages -> Discord
#   (+ daytime @mention), others -> Discord
# - healthchecks-host-ping.timer checks local services every 5m
# - Secrets pass via LoadCredential + EnvironmentFile (never Nix store)
#
# See: doc/o11y/README.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.phlip9-o11y.server;
  cfgA = cfg.alerting;
  cfgVm = config.services.victoriametrics;
  cfgAm = config.services.prometheus.alertmanager;

  alertRules = import ./rules.nix { inherit config lib; };

  inherit (import ../collector/lib.nix { inherit config; }) hostTargets;

  vmalertAddr = "127.0.0.1:8880";
  amAddr = "${cfgAm.listenAddress}:${toString cfgAm.port}";
  amCredsDir = "/run/credentials/alertmanager.service";

  # Grafana base URL for links in ./alertmanager.tmpl.
  grafanaUrlTmpl = pkgs.writeText "grafana-url.tmpl" ''
    {{ define "grafana.url" }}https://${cfg.grafana.domain}{{ end }}
  '';

  # Quiet hours (23:00-09:00 PT; split across midnight since AM rejects wrap).
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

  hostChecks = [
    {
      name = "victoriametrics";
      unit = "victoriametrics.service";
      url = "http://${cfgVm.listenAddress}/health";
    }
    {
      name = "vmalert";
      unit = "vmalert.service";
      url = "http://${vmalertAddr}/health";
    }
    {
      name = "alertmanager";
      unit = "alertmanager.service";
      url = "http://${amAddr}/-/healthy";
    }
  ];

  # Ping healthchecks.io if local checks pass. Exits 0 on unhealthy check so
  # deploy restarts don't trigger `UnitFailed` (hc alerts after grace); a failed
  # curl ping still fails the unit.
  hostPing = pkgs.writeShellApplication {
    name = "healthchecks-host-ping";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      config.systemd.package
    ];
    text = ''
      failed=()

      # Fail unless UNIT is active and URL returns 2xx.
      check() {
        local name=$1 unit=$2 url=$3
        if ! systemctl is-active --quiet "$unit"; then
          failed+=("$name: $unit is not active")
        elif ! curl -fsS -m 5 -o /dev/null "$url" 2> /dev/null; then
          failed+=("$name: GET $url failed")
        fi
      }

      ${lib.concatMapStringsSep "\n" (
        c: "check ${c.name} ${c.unit} ${c.url}"
      ) hostChecks}

      if ((''${#failed[@]} > 0)); then
        printf '%s\n' "''${failed[@]}" >&2
        echo "unhealthy, skipped the ping" >&2
        exit 0
      fi

      # Pass ping URL via private curl config to keep it out of /proc argv.
      umask 077
      conf=$(mktemp)
      trap 'rm -f "$conf"' EXIT
      ping_url=$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/ping-url")
      printf 'url = "%s"\n' "$ping_url" > "$conf"
      curl --config "$conf" -fsS -m 10 -o /dev/null
      echo "healthy, pinged"
    '';
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
        # Heartbeat (./rules.nix) every ~2m; hc expects <= 5m + 5m grace.
        {
          matchers = [ ''alertname="Watchdog"'' ];
          receiver = "healthchecks-watchdog";
          group_by = [ "alertname" ];
          group_wait = "0s";
          group_interval = "1m";
          repeat_interval = "2m";
        }
        # Full page message + resolve, day and night. An always-active receiver
        # must own resolves since AM tracks notification state per receiver and
        # a time-gated receiver drops resolves across window edges.
        {
          matchers = [ ''severity="page"'' ];
          receiver = "discord-quiet";
          repeat_interval = "1h";
          continue = true;
        }
        # Extra daytime @mention (no resolve). Muted at night; pages still
        # firing at 09:00 get mentioned on the next flush.
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
            # Substituted via envsubst from environmentFile at start.
            content = "<@$DISCORD_USER_ID>";
            title = ''{{ template "discord.phlip9.title" . }}'';
            message = ''{{ template "discord.phlip9.mention" . }}'';
            # discord-quiet sends resolves.
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
  options.services.phlip9-o11y.server.alerting = {
    enable = lib.mkEnableOption "alerting (vmalert + Alertmanager)";

    discordWebhookUrlFile = lib.mkOption {
      type = lib.types.path;
      description = "Discord webhook URL file for `#alerts` (secret).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Alertmanager EnvironmentFile w/ `DISCORD_USER_ID=<n>` for daytime page
        @mentions (secret; envsubst'd into config at start).
      '';
    };

    healthchecksWatchdogPingUrlFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        healthchecks.io ping URL file for the `Watchdog` alert (secret).
      '';
    };

    healthchecksHostPingUrlFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        healthchecks.io ping URL file for healthchecks-host-ping (secret).
      '';
    };

    instances = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.strMatching "[A-Za-z0-9_-]+");
      default = [ config.networking.hostName ];
      defaultText = lib.literalExpression "[ config.networking.hostName ]";
      example = [
        "sauna"
        "other-server"
      ];
      description = ''
        Hosts (`instance` labels) receiving host-level alerts (./rules.nix).
        Other hosts' series never fire or affect alerts.
      '';
    };

    groupWait = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = "Test knob for Alertmanager `group_wait`.";
    };

    groupInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "Test knob for Alertmanager `group_interval`.";
    };
  };

  config = lib.mkIf (cfg.enable && cfgA.enable) {
    services.phlip9-o11y.collector.scrapeConfigs = {
      # Follow any httpListenAddr override.
      vmalert.static_configs =
        hostTargets
          config.services.vmalert.instances."".settings.httpListenAddr;
      alertmanager.static_configs = hostTargets amAddr;
    };

    # --- vmalert --- #

    services.vmalert.instances."" = {
      enable = true;
      settings = {
        httpListenAddr = vmalertAddr;
        "datasource.url" = "http://${cfgVm.listenAddress}";
        # Persist `ALERTS` / `ALERTS_FOR_STATE` in VM and restore `for` state.
        "remoteWrite.url" = "http://${cfgVm.listenAddress}";
        "remoteRead.url" = "http://${cfgVm.listenAddress}";
        "notifier.url" = [ "http://${amAddr}" ];
        # Keep in sync w/ nixos/sauna/grafana/overview.json (treats Watchdog
        # as stale after 3m, i.e. > 2 evals).
        evaluationInterval = lib.mkDefault "1m";
        # Base for `generatorURL` links (reachable via
        # `ssh -L 8880:127.0.0.1:8880 sauna`).
        "external.url" = "http://localhost:8880";
      };
      # Other modules may append groups.
      rules.groups = alertRules.groups;
    };

    systemd.services.vmalert = {
      wants = [ "victoriametrics.service" ];
      after = [ "victoriametrics.service" ];

      # Hardening (loopback VM + Alertmanager only).
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

    # --- Alertmanager --- #

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9093;
      # Single node; disable 0.0.0.0:9094 gossip listener.
      extraFlags = [ "--cluster.listen-address=" ];
      # Module envsubsts the config; keep Go templates using `$` in
      # ./alertmanager.tmpl (unsubstituted).
      environmentFile = cfgA.environmentFile;
      configuration = amConfig;
    };

    systemd.services.alertmanager.serviceConfig.LoadCredential = [
      "discord-webhook-url:${cfgA.discordWebhookUrlFile}"
      "healthchecks-watchdog-ping-url:${cfgA.healthchecksWatchdogPingUrlFile}"
    ];

    # --- healthchecks-host-ping --- #

    systemd.services.healthchecks-host-ping = {
      description = "Ping healthchecks.io if the alerting stack is healthy";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe hostPing;
        # Catches hung systemctl (curl calls have own timeouts).
        TimeoutStartSec = "1min";
        LoadCredential = [ "ping-url:${cfgA.healthchecksHostPingUrlFile}" ];
        DynamicUser = true;

        # Hardening (loopback services, systemd D-Bus, HTTPS healthchecks.io).
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
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
          "AF_UNIX"
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

    systemd.timers.healthchecks-host-ping = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/5";
        # Default 1m slack is too wide for a 5m check.
        AccuracySec = "10s";
      };
    };

    assertions = [
      {
        # Notifications link to Grafana.
        assertion = cfg.grafana.domain != null;
        message = "phlip9-o11y: server.alerting needs server.grafana.domain";
      }
      {
        # Reject stray `$` that envsubst would strip (ignore `templates` paths).
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
