# o11y collector: nixos-exporter (nixos/pkgs/nixos-exporter/main.go).
#
# - Metrics: boots, system gen, activation, pending reboot, unit cgroups
# - Socket-activated
# - Starts at boot to count unscraped boots
{
  config,
  lib,
  phlipPkgsNixos,
  ...
}:

let
  cfgC = config.services.phlip9-o11y.collector;
  cfgE = cfgC.nixosExporter;

  inherit (import ./lib.nix { inherit config; }) hostTargets;
in
{
  options.services.phlip9-o11y.collector.nixosExporter = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9101";
      description = "Loopback `/metrics` listen addr.";
    };
  };

  config = lib.mkIf cfgC.enable {
    services.phlip9-o11y.collector.scrapeConfigs.nixos-exporter = {
      static_configs = hostTargets cfgE.listenAddress;
    };

    systemd.sockets.nixos-exporter = {
      description = "nixos-exporter metrics socket";
      wantedBy = [ "sockets.target" ];
      socketConfig.ListenStream = cfgE.listenAddress;
    };

    systemd.services.nixos-exporter = {
      description = "NixOS boot, generation + cgroup metrics exporter";
      requires = [ "nixos-exporter.socket" ];
      after = [ "nixos-exporter.socket" ];
      # Count unscraped boots.
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = lib.getExe phlipPkgsNixos.nixos-exporter;
        DynamicUser = true;
        # Boot count + last boot_id.
        StateDirectory = "nixos-exporter";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening. No ProcSubset=pid (hides /proc/sys/kernel/random/boot_id).
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        IPAddressDeny = [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        # Socket inherited from systemd.
        PrivateNetwork = true;
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
        # Inherited socket accept() still works.
        RestrictAddressFamilies = [ "none" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        UMask = "0077";
      };
    };
  };
}
