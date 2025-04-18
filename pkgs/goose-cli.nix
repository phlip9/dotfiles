# block/goose - AI developer agent cli
{
  dbus,
  fetchFromGitHub,
  fetchurl,
  hostPlatform,
  lib,
  llvmPackages,
  oniguruma,
  pkg-config,
  rustPlatform,
  writableTmpDirAsHomeHook,
  xorg,
  zlib,
  zstd,
}:
rustPlatform.buildRustPackage rec {
  pname = "goose-cli";
  version = "1.0.18";

  src = fetchFromGitHub {
    owner = "block";
    repo = "goose";
    tag = "v${version}";
    hash = "sha256-SCQxr1C02VdnI2rKrLvmuB2U1Ynu9IUoyISrTcmgcB8=";
  };

  cargoHash = "sha256-pKZijhMWCJuliOc4vyXZccbAPpZKi7RNs+NbJDDBFrc=";

  cargoBuildFlags = "-p goose-cli --bin goose";

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs =
    [
      oniguruma
      zlib
      zstd
    ]
    ++ lib.optionals hostPlatform.isLinux [
      dbus
      xorg.libxcb
    ];

  env =
    {
      # Needs older libgit2 version
      # LIBGIT2_NO_VENDOR = true;
      RUSTONIG_SYSTEM_LIBONIG = true;
      ZSTD_SYS_USE_PKG_CONFIG = true;
    }
    // lib.optionalAttrs hostPlatform.isDarwin {
      LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";
    };

  preBuild = let
    gpt-4o-tokenizer-json = fetchurl {
      url = "https://huggingface.co/Xenova/gpt-4o/resolve/31376962e96831b948abe05d420160d0793a65a4/tokenizer.json";
      hash = "sha256-Q6OtRhimqTj4wmFBVOoQwxrVOmLVaDrgsOYTNXXO8H4=";
    };
    claude-tokenizer-json = fetchurl {
      url = "https://huggingface.co/Xenova/claude-tokenizer/resolve/cae688821ea05490de49a6d3faa36468a4672fad/tokenizer.json";
      hash = "sha256-wkFzffJLTn98mvT9zuKaDKkD3LKIqLdTvDRqMJKRF2c=";
    };
  in ''
    mkdir -p tokenizer_files/Xenova--gpt-4o tokenizer_files/Xenova--claude-tokenizer
    ln -s ${gpt-4o-tokenizer-json} tokenizer_files/Xenova--gpt-4o/tokenizer.json
    ln -s ${claude-tokenizer-json} tokenizer_files/Xenova--claude-tokenizer/tokenizer.json
  '';

  doCheck = false;

  nativeCheckInputs = [writableTmpDirAsHomeHook];

  __darwinAllowLocalNetworking = true;

  checkFlags = [
    "--skip=config::base::tests::test_multiple_secrets"
    "--skip=config::base::tests::test_secret_management"
    "--skip=developer::tests::test_global_goosehints"
    "--skip=jetbrains::tests::test_capabilities"
    "--skip=jetbrains::tests::test_router_creation"
    "--skip=providers::oauth::tests::test_token_cache"
  ];

  meta = {
    mainProgram = "goose";
  };
}
