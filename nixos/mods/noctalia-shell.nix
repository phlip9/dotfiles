{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.noctalia-shell;
in
{
  options.services.noctalia-shell = {
    enable = lib.mkEnableOption "Noctalia shell systemd service";

    package = lib.mkPackageOption pkgs "noctalia-shell" { };

    target = lib.mkOption {
      type = lib.types.str;
      default = "graphical-session.target";
      example = "hyprland-session.target";
      description = "The systemd target for the noctalia-shell service.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.noctalia-shell = {
      description = "Noctalia Shell - Wayland desktop shell";
      documentation = [ "https://docs.noctalia.dev" ];
      after = [ cfg.target ];
      partOf = [ cfg.target ];
      wantedBy = [ cfg.target ];

      restartTriggers = lib.mkForce [ ];
      restartIfChanged = true;

      environment = {
        PATH = lib.mkForce null;
      };

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
