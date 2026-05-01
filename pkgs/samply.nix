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
    rev = "0ebb88f1e59c41280fb330ef49f6ef057b7adb1e";
    hash = "sha256-2n7/9cnvr5Nr7JfdvJhNUGnH16Ny/VMVz18TaoECvcg=";
  };

  cargoHash = "sha256-CMG0548b2rfYy/pFXMaGEmkUQHJtwBY7+1UCu6jFE2k=";

  cargoBuildFlags = "-p samply --bin samply";

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
