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
    rev = "bc0cd2fe29c9de471653c0891162569760fa0e5e";
    hash = "sha256-V00FdibSEOjW6pGG1r6ou/IZNds2F4UlSeSJTWHar1I=";
  };

  cargoHash = "sha256-ph7RSTyjNJjboLM2Eq9AIeS91rrwkWUSMINknqOIFE4=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
