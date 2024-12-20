# Set up nixpkgs OpenSSH ssh-agent as a systemd/launchd user service.
{
  config,
  lib,
  pkgs,
  ...
}: let
  isLinux = pkgs.hostPlatform.isLinux;
  isDarwin = pkgs.hostPlatform.isDarwin;

  # ssh-agent socket location
  sshAgentDir =
    if isLinux
    then "$XDG_RUNTIME_DIR"
    # TODO(phlip9): find a better location for the socket on macOS
    else if isDarwin
    then "${config.home.homeDirectory}/.ssh"
    else throw "nix-ssh-agent: config: unrecognized platform";
  sshAgentSock = "nix-ssh-agent.socket";
  sshAgentSockPath = "${sshAgentDir}/${sshAgentSock}";

  # ssh-askpass binary
  ssh-askpass =
    # TODO(phlip9): seahorse is gnome only. choose an askpass impl based on host cfg.
    if isLinux
    then "${pkgs.seahorse}/libexec/seahorse/ssh-askpass"
    # ssh-askpass apple script for macOS: <https://github.com/theseal/ssh-askpass>
    else if isDarwin
    then
      pkgs.fetchurl {
        name = "ssh-askpass";
        url = "https://raw.githubusercontent.com/theseal/ssh-askpass/refs/tags/v1.5.1/ssh-askpass";
        hash = "sha256-bQUuGS3Mb+i4Kt+1mDP203s2W1jlRcpl/7uXA7TUZ+o=";
        executable = true;
      }
    else throw "nix-ssh-agent: config: unrecognized platform";

  shellHook = ''
    export -n SSH_AGENT_LAUNCHER
    export SSH_AUTH_SOCK="${sshAgentSockPath}"
    export SSH_ASKPASS="${ssh-askpass}"
    export SSH_ASKPASS_REQUIRE=force
  '';
in
  lib.mkMerge [
    # Common config
    {
      # ssh-agent env exports
      # Also add this to `bash.initExtra` so it reloads after `hms`.
      home.sessionVariablesExtra = shellHook;
      programs.bash.initExtra = shellHook;
    }

    # Linux - configure systemd service
    (lib.mkIf isLinux {
      systemd.user.services.nix-ssh-agent = {
        Install.WantedBy = ["graphical-session-pre.target"];

        Unit = {
          Description = "nixpkgs OpenSSH agent";
          Documentation = "man:ssh-agent(1)";
        };

        Service = {
          ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/${sshAgentSock}";
          Environment = let
            ssh-askpass-wrapper =
              pkgs.writeScript "ssh-askpass-wrapper"
              ''
                #!${pkgs.runtimeShell} -e
                export DISPLAY="$(systemctl --user show-environment | ${pkgs.gnused}/bin/sed 's/^DISPLAY=\(.*\)/\1/; t; d')"
                export XAUTHORITY="$(systemctl --user show-environment | ${pkgs.gnused}/bin/sed 's/^XAUTHORITY=\(.*\)/\1/; t; d')"
                export WAYLAND_DISPLAY="$(systemctl --user show-environment | ${pkgs.gnused}/bin/sed 's/^WAYLAND_DISPLAY=\(.*\)/\1/; t; d')"
                exec ${ssh-askpass} "$@"
              '';
          in [
            "SSH_ASKPASS=${ssh-askpass-wrapper}"
            "DISPLAY=fake"
          ];
        };
      };
    })

    # macOS - configure launchd service
    (lib.mkIf isDarwin {
      launchd.agents.nix-ssh-agent = {
        enable = true;
        config = {
          Program = let
            run-nix-ssh-agent = pkgs.writeShellScript "run-nix-ssh-agent" ''
              ${pkgs.coreutils}/bin/mkdir -m 700 -p ${sshAgentDir}
              ${pkgs.coreutils}/bin/rm -f ${sshAgentSockPath}
              exec ${pkgs.openssh}/bin/ssh-agent -D -a ${sshAgentSockPath}
            '';
          in "${run-nix-ssh-agent}";
          EnvironmentVariables = {
            SSH_ASKPASS = "${ssh-askpass}";
            SSH_ASKPASS_REQUIRE = "force";
          };
          # StandardErrorPath = "${sshAgentDir}/nix-ssh-agent.err";
          # StandardOutPath = "${sshAgentDir}/nix-ssh-agent.out";
          KeepAlive = true;
          RunAtLoad = true;
          ProcessType = "Background";
        };
      };
    })
  ]
