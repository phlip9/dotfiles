# terranix wrapper
#
# terranix lets you write your terraform config.tf in nix. This wrapper makes
# terranix use the local nixpkgs from the current directory.
{
  callPackage,
  lib,
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

  passthru.terranix-unwrapped = terranix-unwrapped;
  meta = {
    mainProgram = "terranix";
  };
}
