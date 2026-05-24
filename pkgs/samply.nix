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
    rev = "d31a3e9ed59f06d309d6984455c824a03a15f081";
    hash = "sha256-wGYN38owi5ryz9bQX5BOD7D91eYxUE9R7nsSXGIyiLM=";
  };

  cargoHash = "sha256-NFctaIv1bAnW62yE030HJRihVzidabrK3DWDZnxt3Zg=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
