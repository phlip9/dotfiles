{pkgs}: {
  # cli to load .env
  dotenvy = pkgs.callPackage ./dotenvy.nix {};

  # profiler.firefox.org but local
  firefox-profiler = pkgs.callPackage ./firefox-profiler.nix {};
}
