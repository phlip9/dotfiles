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
    rev = "30eb7ee586f11789ac7598f5898441630711ed1f";
    hash = "sha256-JOLTqDiO/pP3qeW6i4QFgrTg7YS47kwUGK79ZoiycNY=";
  };

  cargoHash = "sha256-SKir+N/SyRJc3kPr3OxPraj3eBkzAacnDkwjRl6FUv0=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
