# terranix wrapper
#
# terranix lets you write your terraform config.tf in nix. This wrapper makes
# terranix use the local nixpkgs from the current directory.
{
  callPackage,
  formats,
  lib,
  pkgs,
  sources,
  stdenvNoCC,
}:

let
  # upstream terranix from GitHub
  terranix-unwrapped = callPackage sources.terranix.outPath { };
in

stdenvNoCC.mkDerivation {
  pname = "terranix";
  version =
    if sources.terranix ? revision then
      builtins.substring 0 7 sources.terranix.revision
    else
      "dirty";

  terranix = lib.getExe' terranix-unwrapped "terranix";

  buildCommand = ''
    mkdir -p $out/bin
    substituteAll ${./terranix.sh} $out/bin/terranix
    chmod +x $out/bin/terranix
    patchShebangs $out/bin

    # Link all non-bin directories (share/, etc.) for completions and extras
    for dir in ${terranix-unwrapped}/*/; do
      name=$(basename "$dir")
      [[ "$name" != "bin" ]] && ln -s "$dir" "$out/$name"
    done
  '';

  preferLocalBuild = true;
  allowSubstitutes = false;

  passthru = rec {
    inherit terranix-unwrapped;

    # our evaluated terraform config, used for validating in CI
    terranixCore = import (terranix-unwrapped + "/core/default.nix") {
      inherit pkgs;
      modules = [ ../../config.nix ];
      strip_nulls = true;
    };

    # our terraform config rendered to the standard json file
    configTfJson = (formats.json { }).generate "config.tf.json" terranixCore.config;
  };

  meta = {
    mainProgram = "terranix";
  };
}
