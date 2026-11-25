# Agent Center: a dashboard where Paseo agents raise threads (decisions,
# confirmations, FYIs) and the user answers them.
#
# Runs `agent-center-server` beside our system Paseo daemon, as the Paseo
# user, mirroring its `$PASEO_HOME` and driving its `paseo` CLI. Puts the
# agents' `agent-center` CLI on PATH and an `agent-center-install` script
# that (re)builds the server and restarts it. Optionally serves the dashboard
# at a public https `domain`, behind oauth2-proxy.
#
# The source and its nix packaging live in the private lexe-projects repo,
# while this repo, its CI, and its binary cache are public. So the service
# runs binaries from a mutable nix profile, built from a local checkout by
# `agent-center-install`, not a pinned package in the system closure.
#
# The loopback listener has no auth: it trusts every local client, guarding
# only against browsers by `Host` and `Origin`. So an iptables owner match
# lets only `localClients` connect to it.
#
#   browser --https--> nginx --auth_request--> oauth2-proxy
#                        \--Host/Origin rewrite--v
#   agent --agent-center CLI--> agent-center-server (loopback, owner match)
#                                 |--> paseo CLI --> daemon
#                                 \--reads--> $PASEO_HOME/{agents,..}
#
# see: doc/agent-center.md
# see: nixos/tests/agent-center.nix
# see: ~/dev/lexe-projects/agent-center/doc/SETUP.md
# see: ~/dev/lexe-projects/agent-center/doc/DESIGN.md
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-center;
  paseoCfg = config.services.paseo;
  user = config.users.users.${cfg.user};

  serverExe = "${cfg.profile}/bin/agent-center-server";
  cliExe = "${cfg.profile}/bin/agent-center";
  url = "http://${cfg.listenAddress}";

  # `listenAddress` as `{ host, port }`. Only IPv4 loopback, which the owner
  # match below covers.
  listen =
    let
      parts = lib.splitString ":" cfg.listenAddress;
    in
    {
      host = lib.head parts;
      port = lib.last parts;
    };

  # The agents' CLI, from the profile, pointed at our listener. A shell
  # wrapper, as makeBinaryWrapper asserts its target exists at build time.
  cliWrapper = pkgs.writeShellScriptBin "agent-center" ''
    export AGENT_CENTER_URL="''${AGENT_CENTER_URL:-${url}}"
    exec ${cliExe} "$@"
  '';

  # Build `agent-center` from a lexe-projects checkout into the profile, then
  # restart the server onto it.
  installScript = pkgs.writeShellApplication {
    name = "agent-center-install";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
    ];
    text = ''
      src="''${1:-${cfg.sourceDir}}"
      if [[ "$(id -un)" != ${lib.escapeShellArg cfg.user} ]]; then
        echo "agent-center-install: run as ${cfg.user}" >&2
        exit 1
      fi
      mkdir -p "$(dirname ${cfg.profile})"
      nix build --profile ${cfg.profile} \
        "$src#agent-center"
      /run/wrappers/bin/sudo systemctl restart agent-center.service
      echo "agent-center: running $(readlink -f ${cfg.profile})"
    '';
  };

  # Only `localClients` may open a connection to the listener; the rest get
  # a TCP reset. Matches SYNs only: every SYN has an owning socket, unlike
  # kernel-sent packets (ex: TIME_WAIT ACKs). Root is refused too.
  chain = "agent-center-lo";
  jumpRule = lib.concatStringsSep " " [
    "OUTPUT -o lo -p tcp -d ${listen.host} --dport ${listen.port}"
    "--syn -j ${chain}"
  ];
  firewallStop = ''
    iptables -w -D ${jumpRule} 2>/dev/null || true
    iptables -w -F ${chain} 2>/dev/null || true
    iptables -w -X ${chain} 2>/dev/null || true
  '';
  firewallStart = ''
    ${firewallStop}
    iptables -w -N ${chain}
    ${lib.concatMapStrings (client: ''
      iptables -w -A ${chain} -m owner --uid-owner ${client} -j RETURN
    '') cfg.localClients}
    iptables -w -A ${chain} -p tcp -j REJECT --reject-with tcp-reset
    iptables -w -I ${jumpRule}
  '';
in
{
  options.services.agent-center = {
    enable = lib.mkEnableOption "Agent Center server beside the Paseo daemon";

    user = lib.mkOption {
      type = lib.types.str;
      default = paseoCfg.user;
      defaultText = lib.literalExpression "config.services.paseo.user";
      description = "User to run as. Must be the Paseo daemon's user.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:4400";
      description = ''
        IPv4 loopback `ip:port` to serve the dashboard and agent API on. The
        dashboard API has no auth; never expose it beyond loopback.
      '';
    };

    localClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ cfg.user ] ++ lib.optional (cfg.domain != null) "nginx";
      defaultText = lib.literalExpression ''
        [ cfg.user ] ++ lib.optional (cfg.domain != null) "nginx"
      '';
      description = "Users allowed to connect to `listenAddress`.";
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "agent-center.example.com";
      description = ''
        Public domain for an nginx vhost serving the dashboard, behind
        `services.oauth2-proxy`, which must be configured separately.
      '';
    };

    humanName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Philip";
      description = ''
        Name agents read for the user, ex: "Philip replied". null means
        "the user".
      '';
    };

    profile = lib.mkOption {
      type = lib.types.str;
      default = "${user.home}/.local/state/nix/profiles/agent-center";
      defaultText = lib.literalExpression ''
        "''${home}/.local/state/nix/profiles/agent-center"
      '';
      description = "Mutable nix profile `agent-center-install` builds into.";
    };

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = "${user.home}/dev/lexe-projects";
      defaultText = lib.literalExpression ''"''${home}/dev/lexe-projects"'';
      description = "lexe-projects checkout `agent-center-install` builds.";
    };

    paseoHome = lib.mkOption {
      type = lib.types.str;
      default = paseoCfg.dataDir;
      defaultText = lib.literalExpression "config.services.paseo.dataDir";
      description = "Paseo daemon's `$PASEO_HOME`, which the server mirrors.";
    };

    paseoPackage = lib.mkOption {
      type = lib.types.package;
      default = paseoCfg.package;
      defaultText = lib.literalExpression "config.services.paseo.package";
      description = "Package providing the `paseo` CLI the server runs.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = !paseoCfg.enable || cfg.user == paseoCfg.user;
            message = "services.agent-center.user must be the Paseo user.";
          }
          {
            assertion = listen.host == "127.0.0.1";
            message = "services.agent-center.listenAddress must be 127.0.0.1.";
          }
          {
            # A missing user fails `firewall-start` at runtime.
            assertion = lib.all (lib.flip lib.hasAttr config.users.users) (
              cfg.localClients
            );
            message = "services.agent-center.localClients: undeclared user.";
          }
          {
            # The owner match is iptables only.
            assertion =
              let
                fw = config.networking;
              in
              fw.firewall.enable && !fw.nftables.enable;
            message = "services.agent-center needs the iptables firewall.";
          }
        ];

        environment.systemPackages = [
          cliWrapper
          installScript
        ];

        networking.firewall.extraCommands = firewallStart;
        networking.firewall.extraStopCommands = firewallStop;

        systemd.services.agent-center = {
          description = "Agent Center";
          wantedBy = [ "multi-user.target" ];
          # Starts fine w/o the daemon; `paseo` calls fail and retry.
          after = [ "paseo.service" ];

          # Skip, don't fail, until the first `agent-center-install`.
          unitConfig.ConditionPathExists = serverExe;

          environment = {
            AGENT_CENTER_ADDR = cfg.listenAddress;
            AGENT_CENTER_DATA_DIR = "/var/lib/agent-center";
            AGENT_CENTER_PASEO_BIN = lib.getExe' cfg.paseoPackage "paseo";
            PASEO_HOME = cfg.paseoHome;
            HOME = user.home;
          }
          // lib.optionalAttrs (cfg.humanName != null) {
            AGENT_CENTER_HUMAN_NAME = cfg.humanName;
          };

          serviceConfig = {
            ExecStart = "${serverExe} serve";
            User = cfg.user;
            Group = user.group;
            StateDirectory = "agent-center";
            StateDirectoryMode = "0700";
            Restart = "always";
            RestartSec = 5;

            # Hardening. The `paseo` CLI writes client state in $PASEO_HOME.
            ProtectHome = "read-only";
            ReadWritePaths = [ cfg.paseoHome ];
            ProtectSystem = "strict";
            PrivateTmp = true;
            PrivateDevices = true;
            NoNewPrivileges = true;
            LockPersonality = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
          };
        };
      }

      # --- public vhost --- #

      (lib.mkIf (cfg.domain != null) {
        assertions = [
          {
            assertion = config.services.oauth2-proxy.enable;
            message = "services.agent-center.domain needs oauth2-proxy.";
          }
        ];

        # oauth2-proxy's `auth_request` guards every location but /oauth2/.
        services.oauth2-proxy.nginx = {
          domain = lib.mkDefault cfg.domain;
          virtualHosts.${cfg.domain} = { };
        };

        # The server takes a change only from its own page's `Origin`, and
        # any request only for its own `Host`. Map our https origin to the
        # loopback one; pass any other through, for the server to refuse.
        services.nginx.commonHttpConfig = ''
          map $http_origin $agent_center_origin {
            default $http_origin;
            "https://${cfg.domain}" "${url}";
          }
        '';

        services.nginx.enable = true;
        services.nginx.virtualHosts.${cfg.domain} = {
          forceSSL = lib.mkDefault true;
          enableACME = lib.mkDefault true;
          locations."/" = {
            proxyPass = url;
            # Its Host would clash w/ ours below.
            recommendedProxySettings = false;
            extraConfig = ''
              proxy_set_header Host ${cfg.listenAddress};
              proxy_set_header Origin $agent_center_origin;
              # Attachments: the server's ATTACHMENT_MAX is 10 MiB.
              client_max_body_size 11m;
              # The dashboard's live event stream.
              proxy_buffering off;
              proxy_read_timeout 1h;
            '';
          };
        };
      })
    ]
  );
}
