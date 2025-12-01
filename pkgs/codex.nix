{
  fetchurl,
  lib,
  openssl,
  stdenv,
  nix-update-script,
}:
let
  version = "0.63.0";

  # ```bash
  # $ (export version="0.63.0" target="aarch64-apple-darwin";
  #    nix store prefetch-file "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";)
  # ```
  sources = {
    x86_64-linux = rec {
      target = "x86_64-unknown-linux-gnu";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-15CH4Bit+i7TZgPPCq5WdqT/rVuHGcYi27FbNKfJZ2s=";
    };
    aarch64-darwin = rec {
      target = "aarch64-apple-darwin";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-p6Zsj+EyxWNM3/zLefO7Z+p9SH2dEFLoGPsLpWp+HoY=";
    };
  };

  source = sources.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp codex-${source.target} $out/bin/codex

    runHook postInstall
  '';

  fixupPhase = lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf --set-rpath "${
      lib.makeLibraryPath [
        stdenv.cc.cc
        stdenv.cc.libc
        openssl
      ]
    }" "$out/bin/codex"
    patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$out/bin/codex"
  '';

  passthru.updateScript = nix-update-script { };
}
