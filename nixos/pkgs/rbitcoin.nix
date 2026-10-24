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

  rbitcoin = callPackage (sources.rbitcoin + "/nix/rbitcoin.nix") {
    inherit craneLib;
  };

  # Upstream's package skips tests. Run the product crates' tests in a
  # separate derivation, so package builds don't pay for a second compile.
  # Like upstream CI, use the `test` profile, since test-only helpers are gated
  # on `debug_assertions`. Own deps layer caches the `test` profile deps.
  cargoTestArgs = {
    inherit (rbitcoin) src version;
    pname = "rbitcoin";
    strictDeps = true;
    CARGO_PROFILE = "test";
    cargoExtraArgs = toString [
      "--locked"
      "-p rbitcoin-node"
      "-p rbitcoin-cli"
      "-p rbitcoin-store"
    ];
  };
  cargo-test = craneLib.cargoTest (
    cargoTestArgs
    // {
      cargoArtifacts = craneLib.buildDepsOnly (
        cargoTestArgs // { pname = "rbitcoin-test"; }
      );
      # Only need the test result, not the `target/` dir.
      doInstallCargoArtifacts = false;
      meta.platforms = rbitcoin.meta.platforms;
    }
  );
in
rbitcoin.overrideAttrs (prev: {
  passthru = (prev.passthru or { }) // {
    tests = (prev.passthru.tests or { }) // {
      inherit cargo-test;
    };
  };
})
