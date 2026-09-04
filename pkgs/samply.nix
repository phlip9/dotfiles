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
    rev = "a2252a6ef2ec2c9c77337b71644be58c93c7c6a8";
    hash = "sha256-uaCPOtiF4hPbCXDEOllpH4r9OE/+9igu4dbMjueu5rc=";
  };

  cargoHash = "sha256-ph7RSTyjNJjboLM2Eq9AIeS91rrwkWUSMINknqOIFE4=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
