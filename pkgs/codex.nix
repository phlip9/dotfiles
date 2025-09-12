{
  stdenv,
  fetchurl,
}: let
  version = "0.34.0";

  sources = {
    x86_64-linux = rec {
      target = "x86_64-unknown-linux-gnu";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-cLdIXPzz1hCMQlaZBn1vaUasPYWhKZ2pTotw61oHAos=";
    };
    aarch64-darwin = rec {
      target = "aarch64-apple-darwin";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-IV6090p6pK/2ElUG92bAru/QpXFs7+yVHJgMevcOVYs=";
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
  }
# TODO(phlip9): build from source when nixpkgs gets newer rustc
# {
#   rustPlatform,
#   fetchFromGitHub,
# }:
# rustPlatform.buildRustPackage rec {
#   pname = "codex";
#   version = "0.34.0";
#
#   src = fetchFromGitHub {
#     owner = "openai";
#     repo = "codex";
#     tag = "rust-v${version}";
#     hash = "sha256-C1PXK/5vPFV5cz1dYWV+GaYl0grscb6qCR66BSih5/E=";
#   };
#
#   sourceRoot = "${src.name}/codex-rs";
#
#   cargoHash = "sha256-OMGGgg6hYdZ40vcUxVsWyLentFBj62CYEH3NJ909kYM=";
#
#   cargoBuildFlags = "-p codex-cli --bin codex";
# }

