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
    rev = "d44c4938a77050a34faebaa0426cc9ff75d31897";
    hash = "sha256-Gn6DhSFoMhxV3ISJU6YLwZCxH70FmFCaWibaIMJYeqc=";
  };

  cargoHash = "sha256-HRDDGEijh/QrwKbRe0H+BabnK3HvfIL4J/mdUji4lpI=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
