# `samply` - command-line sampling profiler for macOS and Linux
{
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage {
  pname = "samply";
  version = "0.13.1-unstable-20250124";

  src = fetchFromGitHub {
    owner = "mstange";
    repo = "samply";
    rev = "52e453d3df1ea1f52005897b7887576be4a129ae";
    hash = "sha256-LEJL3t2ceT5QPZodY/9YupxqX8L/pT0L2znwzgNyn68=";
  };

  cargoHash = "sha256-pwU9axN0qAhqmyk04vDmu+YScA5ocqYbTASqjw9o7jE=";

  cargoBuildFlags = "-p samply --bin samply";
}
