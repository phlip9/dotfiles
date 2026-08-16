{
  bubblewrap,
  fetchurl,
  installShellFiles,
  lib,
  makeBinaryWrapper,
  stdenv,
  versionCheckHook,
}:
let
  sources = lib.importJSON ./sources.json;
  source = sources.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "codex";
  inherit (sources) version;

  srcs =
    map
      (
        artifact:
        fetchurl {
          inherit (artifact) url hash;
        }
      )
      [
        source.codex
        source.codeModeHost
      ];

  sourceRoot = ".";

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp codex-${source.target} $out/bin/${
      if stdenv.hostPlatform.isLinux then "codex-unwrapped" else "codex"
    }
    cp codex-code-mode-host-${source.target} $out/bin/codex-code-mode-host
    runHook postInstall
  '';

  postInstall =
    lib.optionalString stdenv.hostPlatform.isLinux ''
      makeBinaryWrapper $out/bin/codex-unwrapped $out/bin/codex \
        --prefix PATH : ${lib.makeBinPath [ bubblewrap ]}
    ''
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      installShellCompletion --cmd codex \
        --bash <($out/bin/codex completion bash)
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
