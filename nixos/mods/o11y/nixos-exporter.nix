# nixos-exporter for the phlip9-o11y stack: NixOS boots, system profile
# generation, last activation, pending reboot, per-unit cgroup usage. See
# nixos/pkgs/nixos-exporter/main.go.
#
# Socket-activated: systemd owns the loopback listener and passes it in, so
# the service itself runs w/o any network access (`PrivateNetwork`).
# VictoriaMetrics scrapes it (see ./default.nix).
#
# The service also starts at boot, not just on the first scrape, so it
# counts boots that never got scraped.
{
  config,
  lib,
  phlipPkgsNixos,
  ...
}:

let
  cfg = config.services.phlip9-o11y;
  cfgE = cfg.nixosExporter;
in
{
  options.services.phlip9-o11y.nixosExporter = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9101";
      description = "nixos-exporter `/metrics` listener. Keep it on loopback.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.sockets.nixos-exporter = {
      description = "nixos-exporter metrics socket";
      wantedBy = [ "sockets.target" ];
      socketConfig.ListenStream = cfgE.listenAddress;
    };

    systemd.services.nixos-exporter = {
      description = "NixOS boot, generation + cgroup metrics exporter";
      requires = [ "nixos-exporter.socket" ];
      after = [ "nixos-exporter.socket" ];
      # Count the boot at boot, not at the first scrape.
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = lib.getExe phlipPkgsNixos.nixos-exporter;
        DynamicUser = true;
        # Boot count + last boot_id: /var/lib/private/nixos-exporter/boots
        StateDirectory = "nixos-exporter";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening. Only reads /proc/sys/kernel/random/boot_id, the system
        # profile, /run/{current,booted}-system, /sys/fs/cgroup (read-only
        # w/ `ProtectControlGroups`), /sys/dev/block, and its
        # StateDirectory.
        # NOTE: no `ProcSubset=pid`, it hides /proc/sys.
        CapabilityBoundingSet = [ "" ];
        DevicePolicy = "closed";
        IPAddressDeny = [ "any" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        # The socket comes from systemd, so no network namespace access.
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
        # No new sockets; accept() on the inherited one still works.
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
