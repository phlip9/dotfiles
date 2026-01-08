{
  fetchurl,
  lib,
  openssl,
  stdenv,
  nix-update-script,
}:
let
  version = "0.79.0";

  # ```bash
  # $ (export version="0.72.0" target="x86_64-unknown-linux-gnu";
  #    nix store prefetch-file "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";)
  # ```
  sources = {
    x86_64-linux = rec {
      target = "x86_64-unknown-linux-gnu";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-qkoT2tww6m6ybalOe5LgGDTBwEtc9Fr4HJTW83PS+C0=";
    };
    aarch64-darwin = rec {
      target = "aarch64-apple-darwin";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-fwHZr05y5HNVf6qjI936Bk0VBqdZ9CWYOoWqX6cJo+o=";
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
