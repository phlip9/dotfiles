# cargoSetupHook now requires system AWS-LC and zstd. Drop once the
# upstream package declares these dependencies.
{
  aws-lc,
  rusty-path-of-building,
  zstd,
}:
rusty-path-of-building.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [
    aws-lc
    zstd
  ];
})
