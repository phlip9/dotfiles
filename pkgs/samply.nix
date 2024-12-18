{
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage {
  pname = "samply";
  version = "0.13.1-unstable-20241210";

  src = fetchFromGitHub {
    owner = "mstange";
    repo = "samply";
    rev = "1cb135d801c4f1a977b7035d04629891f2eb8b6b";
    hash = "sha256-rpVPvzHnCZCnKDGdFKLAQtrzK1BuP+eGjod67L0pNzU=";
  };

  cargoHash = "sha256-tH8uy8okQ43JRs13WgKuzkp5Mjkbx6wBXczJZ0Ek5mw=";

  cargoBuildFlags = "-p samply --bin samply";
}
