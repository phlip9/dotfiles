# terranix wrapper
#
# terranix lets you write your terraform config.tf in nix. This wrapper makes
# terranix use the local nixpkgs from the current directory.
{
  lib,
  stdenvNoCC,
  runCommandWith,
  # wrap terranix from nixpkgs
  terranix,
}:

runCommandWith
  rec {
    name = "terranix";
    stdenv = stdenvNoCC;
    runLocal = true;
    derivationArgs = {
      terranix = lib.getExe' terranix "terranix";
      passthru.terranix = terranix;
      meta = {
        mainProgram = name;
      };
    };
  }
  ''
    mkdir -p $out/bin
    substituteAll ${./terranix.sh} $out/bin/terranix
    chmod +x $out/bin/terranix
    patchShebangs $out/bin

    # Link all non-bin directories (share/, etc.) for completions and extras
    for dir in ${terranix}/*/; do
      name=$(basename "$dir")
      [[ "$name" != "bin" ]] && ln -s "$dir" "$out/$name"
    done
  ''
