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
    rev = "884f982d304f8a3b1f9fc13efeecb5932003a522";
    hash = "sha256-yFHostcN2O2H4tg4ZNr4ftAvItKA1UPipCiDG4n3cUo=";
  };

  cargoHash = "sha256-5gXQggMxyGrivTsWALUSOudyKUkguYfBljeKf+8Ya+c=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
