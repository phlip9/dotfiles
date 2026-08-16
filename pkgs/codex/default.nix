{
  bubblewrap,
  fetchurl,
  installShellFiles,
  lib,
  makeBinaryWrapper,
  stdenv,
  versionCheckHook,
  zstd,
}:
let
  sources = lib.importJSON ./sources.json;
  source = sources.${stdenv.hostPlatform.system};
  codexSource = fetchurl {
    inherit (source.codex) url hash;
  };
  codeModeHostSource = fetchurl {
    inherit (source.codeModeHost) url hash;
  };
in
stdenv.mkDerivation {
  pname = "codex";
  inherit (sources) version;

  dontUnpack = true;
  dontPatch = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
    zstd
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    codex_bin=$out/bin/${
      if stdenv.hostPlatform.isLinux then "codex-unwrapped" else "codex"
    }
    code_mode_host_bin=$out/bin/codex-code-mode-host

    zstd --decompress --stdout ${codexSource} > "$codex_bin"
    zstd --decompress --stdout ${codeModeHostSource} > "$code_mode_host_bin"
    chmod +x "$codex_bin" "$code_mode_host_bin"

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

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

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
