# Extension module around rbitcoin's upstream NixOS module.
{
  config,
  lib,
  phlipPkgsNixos,
  ...
}:

let
  cfg = config.services.rbitcoin;
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
  ];
}
