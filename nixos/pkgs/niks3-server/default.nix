# niks3-server, w/ patches
{
  callPackage,
  sources,
}:
(callPackage (sources.niks3 + "/nix/packages/niks3-server.nix") { })
.overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [
      # make inventory metrics refresh interval configurable
      # (`--inventory-refresh-interval`, `NIKS3_INVENTORY_REFRESH_INTERVAL`).
      # Upstream hardcodes 1 min, so the nixbot test waited up to a minute for
      # `niks3_cache_objects` to count an upload.
      ./inventory-refresh-interval.patch
    ];
  })
