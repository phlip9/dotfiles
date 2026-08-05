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
    rev = "cd249936e3ffe70ec2c57e3f98cc1f571c89ff6d";
    hash = "sha256-bHqQTRf0Zl6aO5lPABKKjwDi2qMrMa8F+hhOuKa63Ag=";
  };

  cargoHash = "sha256-FnNHyIAdpmXsikgSqnZBjRa/E9ivDt/rd/S1WgtG/Do=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
