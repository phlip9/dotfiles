# Agent Center: a dashboard where Paseo agents raise threads (decisions,
# confirmations, FYIs) and the user answers them.
#
# Runs `agent-center-server` beside our system Paseo daemon, as the Paseo
# user, mirroring its `$PASEO_HOME` and driving its `paseo` CLI. Puts the
# agents' `agent-center` CLI on PATH and an `agent-center-install` script
# that (re)builds the server and restarts it.
#
# The source and its nix packaging live in the private lexe-projects repo,
# while this repo, its CI, and its binary cache are public. So the service
# runs binaries from a mutable nix profile, built from a local checkout by
# `agent-center-install`, not a pinned package in the system closure.
#
#   browser --ssh -L--> agent-center-server (loopback) --> paseo CLI --> daemon
#   agent --agent-center CLI--^           \--reads--> $PASEO_HOME/{agents,..}
#
# see: doc/agent-center.md
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
        Loopback `ip:port` to serve the dashboard and agent API on. The
        dashboard API has no auth; never expose it beyond loopback.
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = paseoCfg.enable && cfg.user == paseoCfg.user;
        message = "services.agent-center needs services.paseo, as its user.";
      }
    ];

    environment.systemPackages = [
      cliWrapper
      installScript
    ];

    systemd.services.agent-center = {
      description = "Agent Center";
      wantedBy = [ "multi-user.target" ];
      # Starts fine w/o the daemon; `paseo` calls fail and retry until it's up.
      wants = [ "paseo.service" ];
      after = [ "paseo.service" ];

      # Skip, don't fail, until the first `agent-center-install`.
      unitConfig.ConditionPathExists = serverExe;

      environment = {
        AGENT_CENTER_ADDR = cfg.listenAddress;
        AGENT_CENTER_DATA_DIR = "/var/lib/agent-center";
        AGENT_CENTER_PASEO_BIN = lib.getExe' paseoCfg.package "paseo";
        PASEO_HOME = paseoCfg.dataDir;
        HOME = user.home;
      }
      // lib.optionalAttrs (cfg.humanName != null) {
        AGENT_CENTER_HUMAN_NAME = cfg.humanName;
      };

      serviceConfig = {
        ExecStart = "${serverExe} serve";
        User = cfg.user;
        Group = paseoCfg.group;
        StateDirectory = "agent-center";
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 5;

        # Hardening. The `paseo` CLI writes client state in $PASEO_HOME.
        ProtectHome = "read-only";
        ReadWritePaths = [ paseoCfg.dataDir ];
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
  };
}
