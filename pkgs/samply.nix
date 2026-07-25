# `samply` - command-line sampling profiler for macOS and Linux
{
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "samply";
  version = "0.13.1-unstable-${builtins.substring 0 8 finalAttrs.src.rev}";

  src = fetchFromGitHub {
    owner = "mstange";
    repo = "samply";
    rev = "111b0a401e06b3e26c00a36c8afc015050d68b1d";
    hash = "sha256-EffHTFk+dM0neqIxi6N9mB0ekiMO/7JHlxMLGlMdgMg=";
  };

  cargoHash = "sha256-qikyLqlY7chDmZaBIksBFM1b6DuE/WJlKiO6pwRA/0U=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
