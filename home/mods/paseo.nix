# Run paseo as a background user daemon service.
{
  config,
  lib,
  phlipPkgs,
  pkgs,
  ...
}:
let
  # isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  cfg = config.services.paseo;

  listen = "${cfg.listenAddress}:${toString cfg.port}";
  paseoHome = "${config.xdg.configHome}/paseo";
  paseoPath = lib.makeBinPath (
    [
      cfg.package
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.git
      pkgs.openssh
    ]
    ++ lib.optionals isDarwin [
      # macOS launchd services start with a tiny system PATH. Include the
      # user profiles so agent processes can find CLIs installed by HM/Nix.
      pkgs.gnugrep
      pkgs.gnused
    ]
  );
in
{
  options.services.paseo = {
    enable = lib.mkEnableOption "self-hosted agent interface";

    package = lib.mkOption {
      type = lib.types.package;
      default = phlipPkgs.paseo;
      description = "Paseo package to run.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the Paseo daemon to bind to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6767;
      description = "Port for the Paseo daemon to listen on.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the Paseo daemon.";
    };

    relay = {
      enable = lib.mkEnableOption "remote relay";
    };
  };

  config = lib.mkIf cfg.enable {
    # Add paseo to PATH
    home.packages = [ cfg.package ];

    home.sessionVariables = {
      PASEO_HOME = paseoHome;
      PASEO_HOST = listen;
    };

    # Need some way to create this dir on macOS before the service starts
    xdg.configFile."paseo/.keep" = lib.mkIf isDarwin { text = ""; };

    # macOS - launchd agent
    launchd.agents.paseo = lib.mkIf isDarwin {
      enable = true;
      config = {
        Program =
          let
            runPaseo = pkgs.writeShellScript "run-paseo" ''
              set -euxo pipefail

              export PATH="$PATH:${
                lib.concatStringsSep ":" [
                  "${config.home.profileDirectory}/bin"
                  "${config.home.homeDirectory}/.nix-profile/bin"
                  "${config.home.homeDirectory}/.local/state/nix/profile/bin"
                  paseoPath
                ]
              }"
              mkdir -p "${paseoHome}"

              exec ${cfg.package}/bin/paseo-server ${
                lib.optionalString (!cfg.relay.enable) "--no-relay"
              }
            '';
          in
          "${runPaseo}";
        WorkingDirectory = paseoHome;
        StandardErrorPath = "${paseoHome}/paseo.err.log";
        StandardOutPath = "${paseoHome}/paseo.out.log";
        EnvironmentVariables = {
          NODE_ENV = "production";
          PASEO_HOME = paseoHome;
          PASEO_LISTEN = listen;
          PASEO_HOST = listen;
        }
        // cfg.environment;
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
          Crashed = true;
        };
        ProcessType = "Background";
        ThrottleInterval = 5;
      };
    };
  };
}
