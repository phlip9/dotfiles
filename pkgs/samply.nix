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
    rev = "dea56099bba34dfc5da4a8c9365d90b6eabffac7";
    hash = "sha256-ydBgyohIOtbvol1TvGfse2b8adhONge4G7x68sBOda0=";
  };

  cargoHash = "sha256-pncRQ0ZCw7ZUZvxZ9mSaZA8kOrvM1oQwHAG+6eQ6K0c=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
