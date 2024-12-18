{pkgs}: let
  callPackage = pkgs.callPackage;
in {
  # cli to load .env
  dotenvy = callPackage ./dotenvy.nix {};

  # profiler.firefox.org but local
  firefox-profiler = callPackage ./firefox-profiler.nix {};

  # sampling profiler written in Rust, with native firefox-profiler integration
  samply = callPackage ./samply.nix {};
}
