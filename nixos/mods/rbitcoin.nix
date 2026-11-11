# Extension module around rbitcoin's upstream NixOS module.
#
# Readiness:
# - `rbitcoin.service` (`Type=notify`): active once the datadir is locked,
#   before the store opens. Boot and deploys only wait for this.
# - `rbitcoin-synced.target`: active once `/readyz` first answers ok
#   (following a fresh tip, scripthash index caught up) and every listener
#   (RPC, Electrum, Esplora, ...) is up. Nothing waits for it but its
#   dependents. A node whose tip stays stale (no peers, regtest at genesis)
#   never gets there.
#
# A service that needs a synced node: `wantedBy` + `after` + `requisite` the
# target, and `partOf` it to also stop w/ the node. Never `wants`/`requires`
# it: starting the target w/o the marker only skips it (see
# `ConditionPathExists`), so the dependent would start anyway.
#
# Synced is reported once per node process. If the node later falls behind,
# the target stays active; `/readyz` and the o11y rbitcoin alerts cover that.
{
  config,
  lib,
  pkgs,
  phlipPkgsNixos,
  ...
}:

let
  cfg = config.services.rbitcoin;

  # `startupNotify` creates the marker once the node is synced. It lives in
  # the unit's RuntimeDirectory, which systemd removes whenever the node
  # stops, crashes, or fails, so it never outlives the process that wrote it.
  # Not /run/rbitcoin, which upstream suggests for `rpc.socketPath`.
  readyDir = "rbitcoin-ready";
  syncedMarker = "/run/${readyDir}/synced";
  touch = lib.getExe' pkgs.coreutils "touch";

  # The node runs these hooks w/ `sh -c`.
  hasShellHooks = cfg.startupNotify != null || cfg.alertNotify != null;
in
{
  config = lib.mkMerge [
    {
      # Upstream defaults to its flake's static musl build. Use our glibc build
      # against nixos-unstable instead.
      services.rbitcoin.package = lib.mkDefault phlipPkgsNixos.rbitcoin;
    }

    # Our package's sd-notify patch sends `READY=1` once the datadir is
    # locked, before the store opens. Start jobs (boot, restarts, deploys)
    # then fail fast on a bad config or a locked datadir, but never wait out
    # a schema migration or catch-up. `systemctl status` shows the phase.
    (lib.mkIf (cfg.enable && cfg.package.passthru.sdNotify or false) {
      systemd.services.rbitcoin.serviceConfig.Type = "notify";
    })

    (lib.mkIf cfg.enable {
      # Defined at normal priority, so a second `startupNotify` is a
      # conflict, not a silently missing marker.
      services.rbitcoin.startupNotify = "${touch} ${syncedMarker}";
      systemd.services.rbitcoin.serviceConfig.RuntimeDirectory = readyDir;

      # Starts the target once the marker exists. Started w/ the node, and
      # stopped or restarted w/ it by systemctl (`PartOf=` doesn't follow a
      # clean exit, e.g. RPC `stop`, but then the marker is gone anyway). It
      # also checks on start, so a marker written before the watch began
      # still triggers.
      systemd.paths.rbitcoin-synced = {
        description = "Watch for the rbitcoin synced marker";
        wantedBy = [ "rbitcoin.service" ];
        partOf = [ "rbitcoin.service" ];
        pathConfig = {
          PathExists = syncedMarker;
          Unit = "rbitcoin-synced.target";
        };
      };

      systemd.targets.rbitcoin-synced = {
        description = "rbitcoin node caught up, all listeners up";
        # Stops whenever the node stops, crashes, or restarts.
        bindsTo = [ "rbitcoin.service" ];
        after = [ "rbitcoin.service" ];
        # Never active w/o the marker, even if pulled in as a dependency.
        unitConfig.ConditionPathExists = syncedMarker;
      };
    })

    # The unit's default PATH has no shell, so the node's `sh -c` hooks would
    # only log a warning.
    (lib.mkIf (cfg.enable && hasShellHooks) {
      systemd.services.rbitcoin.path = [ pkgs.bash ];
    })

    # Sandbox the node beyond upstream's NoNewPrivileges, PrivateTmp,
    # ProtectHome, and ProtectSystem=strict. It parses untrusted P2P and
    # API input. Check w/ `systemd-analyze security rbitcoin.service`;
    # nixos/tests/rbitcoin.nix fails if the exposure score regresses.
    (lib.mkIf cfg.enable {
      systemd.services.rbitcoin.serviceConfig = {
        # Unprivileged user. P2P and all listeners use ports > 1024.
        CapabilityBoundingSet = "";
        # Owner-only files by default. The node chmods the files it shares,
        # ex: the 0660 `rpc.socketPath` socket.
        UMask = "0077";

        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        PrivateDevices = true;
        # NOTE: hides the tor control cookie's group. Revisit w/ Tor.
        PrivateUsers = true;
        ProtectClock = true;
        # Read-only. The node reads its cgroup's memory limits to size its
        # IBD + index workers.
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        # Not `ProcSubset = "pid"`: the node reads /proc/meminfo
        # (MemAvailable) to size those same workers.
        ProtectProc = "invisible";
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;

        # AF_UNIX: sd_notify, unix RPC. No AF_NETLINK: the node learns its
        # public address from peers and never lists interfaces.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];

        SystemCallArchitectures = "native";
        # io_uring is the node's default bulk store IO backend
        # (`RBITCOIN_IO`), but isn't in @system-service. W/o it, the node
        # falls back to pread w/ only a warning. `~@resources` still allows
        # `prlimit64`, which glibc's `setrlimit` uses to raise NOFILE.
        SystemCallFilter = [
          "@system-service"
          "io_uring_enter"
          "io_uring_register"
          "io_uring_setup"
          "~@privileged"
          "~@resources"
        ];
        SystemCallErrorNumber = "EPERM";
      };
    })
  ];
}
