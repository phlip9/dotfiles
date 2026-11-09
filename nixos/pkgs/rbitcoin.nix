# rbitcoin - Bitcoin full node + Electrum + Esplora server, written in Rust.
#
# Wraps upstream's crane package (`<rbitcoin>/nix/rbitcoin.nix`). We build
# against our nixos-unstable `pkgs`, so this is the dynamic glibc build, not
# upstream's static musl release build.
{
  callPackage,
  lib,
  pkgs,
  sources,
}:

let
  craneLib = import sources.crane { inherit pkgs; };

  # Keep symbols + frame pointers for the eBPF profiler (Alloy
  # `pyroscope.ebpf`): it unwinds user stacks by frame pointer and
  # symbolizes from the on-disk `.symtab`. nixpkgs `buildRustPackage` gets
  # FPs via `cargoSetupHook`; crane doesn't, and upstream strips all
  # symbols (`-C strip=symbols`).
  #
  # Upstream's `commonRUSTFLAGS` is a `let` binding, so patch the RUSTFLAGS
  # env vars on every crane builder call instead. This covers both the deps
  # layer (`buildDepsOnly`) and the app layer (`buildPackage`), so the app
  # build reuses a deps layer w/ matching flags. `strip=debuginfo` keeps
  # `.symtab` but still drops DWARF.
  patchRustflags =
    flags:
    assert lib.assertMsg (lib.hasInfix "-C strip=symbols" flags)
      "rbitcoin: upstream RUSTFLAGS changed: ${flags}";
    builtins.replaceStrings [ "-C strip=symbols" ] [ profilingFlags ] flags;
  profilingFlags = "-C strip=debuginfo -C force-frame-pointers=yes";
  isRustflagsVar =
    name: builtins.match "(CARGO_TARGET_.*_)?RUSTFLAGS" name != null;
  patchArgs = lib.mapAttrs (
    name: value: if isRustflagsVar name then patchRustflags value else value
  );
  profilingCraneLib = craneLib.overrideScope (
    final: prev: {
      buildDepsOnly = args: prev.buildDepsOnly (patchArgs args);
      buildPackage = args: prev.buildPackage (patchArgs args);
    }
  );

  rbitcoin = callPackage (sources.rbitcoin + "/nix/rbitcoin.nix") {
    craneLib = profilingCraneLib;
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
