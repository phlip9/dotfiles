# rbitcoin - Bitcoin full node + Electrum + Esplora server, written in Rust.
#
# Wraps upstream's crane package (`<rbitcoin>/nix/rbitcoin.nix`). We build
# against our nixos-unstable `pkgs`, so this is the dynamic glibc build, not
# upstream's static musl release build.
{
  callPackage,
  pkgs,
  sources,
}:

let
  craneLib = import sources.crane { inherit pkgs; };
in
callPackage (sources.rbitcoin + "/nix/rbitcoin.nix") {
  inherit craneLib;
}
