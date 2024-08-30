# Set up nixpkgs OpenSSH ssh-agent as a systemd user service.
{
  lib,
  pkgs,
  ...
}: let
  # TODO(phlip9): seahorse is gnome only. choose an askpass impl based on host cfg.
  ssh-askpass = "${pkgs.seahorse}/libexec/seahorse/ssh-askpass";

  shellHook = ''
    export -n SSH_AGENT_LAUNCHER
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/nix-ssh-agent"
    export SSH_ASKPASS="${ssh-askpass}"
  '';
in {
  # systemd only works on linux
  assertions = [
    (lib.hm.assertions.assertPlatform "services.nix-ssh-agent" pkgs lib.platforms.linux)
  ];

  # ssh-agent env exports
  # Also add this to `bash.initExtra` so it reloads after `hms`.
  home.sessionVariablesExtra = shellHook;
  programs.bash.initExtra = shellHook;

  systemd.user.services.nix-ssh-agent = {
    Install.WantedBy = ["graphical-session-pre.target"];

    Unit = {
      Description = "nixpkgs OpenSSH agent";
      Documentation = "man:ssh-agent(1)";
    };

    Service = {
      ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/nix-ssh-agent";
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
}
