# niks3 client CLI, w/ patches
{
  callPackage,
  sources,
}:
(callPackage (sources.niks3 + "/nix/packages/niks3.nix") { }).overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [
      # pass `--json-format 1` to `nix path-info --json`. Nix 2.35 warns
      # on every push when the format is unspecified. v1 is the current
      # default output, so the parser is unchanged. Remove once upstream
      # pins it.
      ./path-info-json-format.patch
    ];
  })
