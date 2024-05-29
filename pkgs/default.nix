{pkgs}: {
  # cli to load .env
  dotenvy = pkgs.callPackage ./dotenvy.nix {};
}
