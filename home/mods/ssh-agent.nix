# Set up nixpkgs OpenSSH ssh-agent as a systemd/launchd user service.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nix-ssh-agent;

  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # ssh-agent socket location
  sshAgentDir =
    if isLinux then
      "$XDG_RUNTIME_DIR"
    # TODO(phlip9): find a better location for the socket on macOS
    else if isDarwin then
      "$(${lib.getExe pkgs.getconf} DARWIN_USER_TEMP_DIR)"
    else
      throw "nix-ssh-agent: config: unrecognized platform";
  sshAgentSock = "nix-ssh-agent.socket";
  sshAgentSockPath = "${sshAgentDir}/${sshAgentSock}";

  shellHook = ''
    export -n SSH_AGENT_LAUNCHER
    export SSH_AUTH_SOCK="${sshAgentSockPath}"
  ''
  + lib.optionalString (cfg.ssh-askpass != null) ''
    export SSH_ASKPASS="${cfg.ssh-askpass}"
    export SSH_ASKPASS_REQUIRE=force
  '';
in
{
  options = {
    services.nix-ssh-agent = {
      ssh-askpass = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if isLinux then
            "${pkgs.seahorse}/libexec/seahorse/ssh-askpass"
          # ssh-askpass apple script for macOS: <https://github.com/theseal/ssh-askpass>
          else if isDarwin then
            "${pkgs.fetchurl {
              name = "ssh-askpass";
              url = "https://raw.githubusercontent.com/theseal/ssh-askpass/refs/tags/v1.5.1/ssh-askpass";
              hash = "sha256-bQUuGS3Mb+i4Kt+1mDP203s2W1jlRcpl/7uXA7TUZ+o=";
              executable = true;
            }}"
          else
            null;
        description = ''
          Path to binary used by ssh-agent to prompt user for ssh key passwords
          and yubikey touches.
        '';
      };
    };
  };

  config = {
    # Common config
    # ssh-agent env exports
    # Also add this to `bash.initExtra` so it reloads after `hms`.
    home.sessionVariablesExtra = shellHook;
    programs.bash.initExtra = shellHook;

    # Linux - configure systemd user service
    systemd.user.services.nix-ssh-agent = lib.mkIf isLinux {
      Install.WantedBy = [ "default.target" ];

      Unit = {
        Description = "nixpkgs OpenSSH agent";
        Documentation = "man:ssh-agent(1)";
      };

      Service = {
        ExecStart = "${lib.getExe' pkgs.openssh "ssh-agent"} -D -a %t/${sshAgentSock}";
        Environment = lib.optionals (cfg.ssh-askpass != null) ([
          "DISPLAY=fake"
          "SSH_ASKPASS=${pkgs.writeScript "ssh-askpass-wrapper" ''
            #!${lib.getExe pkgs.bash} -e
            export DISPLAY="$(systemctl --user show-environment | ${lib.getExe pkgs.gnused} 's/^DISPLAY=\(.*\)/\1/; t; d')"
            export XAUTHORITY="$(systemctl --user show-environment | ${lib.getExe pkgs.gnused} 's/^XAUTHORITY=\(.*\)/\1/; t; d')"
            export WAYLAND_DISPLAY="$(systemctl --user show-environment | ${lib.getExe pkgs.gnused} 's/^WAYLAND_DISPLAY=\(.*\)/\1/; t; d')"
            exec ${cfg.ssh-askpass} "$@"
          ''}"
        ]);
        SuccessExitStatus = 2;
      };
    };

    # macOS - configure launchd agent
    launchd.agents.nix-ssh-agent = lib.mkIf isDarwin {
      enable = true;
      config = {
        ProgramArguments = [
          (lib.getExe pkgs.bash)
          "-c"
          ''${lib.getExe' pkgs.openssl "ssh-agent"} -D -a "${sshAgentSockPath}"''
        ];
        EnvironmentVariables = lib.optionalAttrs (cfg.ssh-askpass != null) {
          SSH_ASKPASS = "${cfg.ssh-askpass}";
          SSH_ASKPASS_REQUIRE = "force";
        };
        # StandardErrorPath = "${sshAgentDir}/nix-ssh-agent.err";
        # StandardOutPath = "${sshAgentDir}/nix-ssh-agent.out";
        KeepAlive = true;
        RunAtLoad = true;
        ProcessType = "Background";
      };
    };
  };
}
