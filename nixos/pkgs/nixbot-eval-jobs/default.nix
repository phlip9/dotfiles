# nixbot's exported nix-eval-jobs evaluator, including its matching patched
# Nix CLI (`passthru.nix`).
{
  callPackage,
  sources,
}:
(callPackage (sources.nixbot + "/packages") { }).nix-eval-jobs.overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [
      # Don't probe substituters for inputs of drvs whose own validity is
      # still pending. Those inputs are often never needed: CI evals probed
      # ~1.5-4x the paths their results need, ~0.3s per cold narinfo.
      # Drop once upstream.
      ./prune-substituter-probes.patch
    ];
  })
