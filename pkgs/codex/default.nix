{
  bubblewrap,
  fetchurl,
  lib,
  libcap,
  makeBinaryWrapper,
  openssl,
  stdenv,
  versionCheckHook,
  zlib,
}:
let
  sources = lib.importJSON ./sources.json;
  source = sources.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "codex";
  inherit (sources) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  sourceRoot = ".";

  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp codex-${source.target} $out/bin/${
      if stdenv.hostPlatform.isLinux then "codex-unwrapped" else "codex"
    }
    runHook postInstall
  '';

  postInstall = lib.optionalString stdenv.hostPlatform.isLinux ''
    makeBinaryWrapper $out/bin/codex-unwrapped $out/bin/codex \
      --prefix PATH : ${lib.makeBinPath [ bubblewrap ]}
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  passthru.updateScript = ./update.sh;

  meta = {
    description = "OpenAI Codex CLI";
    homepage = "https://github.com/openai/codex";
    mainProgram = "codex";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}
