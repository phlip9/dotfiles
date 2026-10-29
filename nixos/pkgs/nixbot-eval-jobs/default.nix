# nixbot's exported nix-eval-jobs evaluator, including its matching patched
# Nix CLI (`passthru.nix`).
{
  callPackage,
  sources,
}:
(callPackage (sources.nixbot + "/packages") { }).nix-eval-jobs
