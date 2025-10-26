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
  protobuf,
  rustPlatform,
  xorg,
  zlib,
  zstd,
}:
rustPlatform.buildRustPackage rec {
  pname = "goose-cli";
  version = "1.0.29";

  src = fetchFromGitHub {
    owner = "block";
    repo = "goose";
    tag = "v${version}";
    hash = "sha256-R4hMGW9YKsvWEvSzZKkq5JTzBXGK2rXyOPB6vzMKbs0=";
  };

  cargoHash = "sha256-EEivL+6XQyC9FkGnXwOYviwpY8lk7iaEJ1vbQMk2Rao=";

  cargoBuildFlags = "-p goose-cli --bin goose";

  nativeBuildInputs = [
    pkg-config
    protobuf
  ];

  buildInputs = [
    oniguruma
    zlib
    zstd
  ]
  ++ lib.optionals hostPlatform.isLinux [
    dbus
    xorg.libxcb
  ];

  env = {
    # Needs older libgit2 version
    # LIBGIT2_NO_VENDOR = true;
    RUSTONIG_SYSTEM_LIBONIG = true;
    ZSTD_SYS_USE_PKG_CONFIG = true;
  }
  // lib.optionalAttrs hostPlatform.isDarwin {
    LIBCLANG_PATH = "${lib.getLib llvmPackages.libclang}/lib";
  };

  preBuild =
    let
      gpt-4o-tokenizer-json = fetchurl {
        url = "https://huggingface.co/Xenova/gpt-4o/resolve/31376962e96831b948abe05d420160d0793a65a4/tokenizer.json";
        hash = "sha256-Q6OtRhimqTj4wmFBVOoQwxrVOmLVaDrgsOYTNXXO8H4=";
      };
      claude-tokenizer-json = fetchurl {
        url = "https://huggingface.co/Xenova/claude-tokenizer/resolve/cae688821ea05490de49a6d3faa36468a4672fad/tokenizer.json";
        hash = "sha256-wkFzffJLTn98mvT9zuKaDKkD3LKIqLdTvDRqMJKRF2c=";
      };
    in
    ''
      mkdir -p tokenizer_files/Xenova--gpt-4o tokenizer_files/Xenova--claude-tokenizer
      ln -s ${gpt-4o-tokenizer-json} tokenizer_files/Xenova--gpt-4o/tokenizer.json
      ln -s ${claude-tokenizer-json} tokenizer_files/Xenova--claude-tokenizer/tokenizer.json
    '';

  doCheck = false;

  meta = {
    mainProgram = "goose";
  };
}
