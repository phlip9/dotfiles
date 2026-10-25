# nixbot CI service, patched to upload outputs it skips as already present in
# the local store. Upstream only uploads outputs that nixbot builds itself, so
# anything built on the CI host beforehand (agents, manual `nix build`) never
# reaches the binary cache.
#
# Remove this patch once upstream uploads `skipped_local` outputs.
{
  callPackage,
  sources,
  nixbot-eval-jobs,
}:
(callPackage (sources.nixbot + "/packages/nixbot.nix") {
  nix-eval-jobs = nixbot-eval-jobs;
}).overridePythonAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [ ./upload-skipped-local.patch ];
  })
