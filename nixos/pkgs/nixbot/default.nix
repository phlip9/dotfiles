# nixbot CI service, w/ patches
{
  callPackage,
  sources,
  nixbot-eval-jobs,
}:
(callPackage (sources.nixbot + "/packages/nixbot.nix") {
  nix-eval-jobs = nixbot-eval-jobs;
}).overridePythonAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [
      # upload outputs it skips as already present in the local store. Upstream
      # only uploads outputs that nixbot builds itself, so anything built on
      # the CI host beforehand (agents, manual `nix build`) never reaches the
      # binary cache. Remove once upstream uploads `skipped_local` outputs.
      ./upload-skipped-local.patch
      # `NIXBOT_METRICS_CACHE_TTL` overrides the hardcoded 15s `/metrics`
      # cache, so the nixbot test sees fresh build counts. Remove once upstream
      # makes the TTL configurable.
      ./metrics-cache-ttl.patch
    ];
  })
