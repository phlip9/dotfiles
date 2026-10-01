{
  bubblewrap,
  fetchurl,
  installShellFiles,
  lib,
  makeBinaryWrapper,
  ripgrep,
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

  # Mirrors the `codex-package.json` in upstream's `codex-package-*` tarballs.
  # `codex` checks `target`, `entrypoint`, and `version` against itself.
  env.CODEX_PACKAGE_MANIFEST_JSON = builtins.toJSON {
    layoutVersion = 1;
    inherit (sources) version;
    inherit (source) target;
    variant = "codex";
    entrypoint = "bin/codex";
    resourcesDir = "codex-resources";
    pathDir = "codex-path";
  };

  # Since 0.159, `codex` locates its package root via `realpath(current_exe)`
  # and refuses to start its app-server daemon unless the package is complete:
  #
  # - codex-package.json
  # - bin/codex
  # - bin/codex-code-mode-host
  # - codex-path/rg
  # - codex-resources/bwrap (linux only)
  #
  # The daemon copies the package dir into `$CODEX_HOME/packages/` and rejects
  # symlinks that escape the package, so `codex-path/` gets small exec wrappers
  # pointing at nixpkgs `rg` and `bwrap` instead. `codex` prepends `codex-path`
  # to its own PATH at startup, so the daemon, sandbox helper, and agent shells
  # all find them.
  #
  # linux: `codex` prefers a `bwrap` on PATH over `codex-resources/bwrap`,
  # which must match a sha256 digest baked into the release binary. Leave an
  # empty executable placeholder there to satisfy the completeness check. If
  # codex ever uses the fallback, the digest check will fail closed.
  installPhase = ''
    runHook preInstall

    pkg=$out/libexec/codex
    mkdir -p $out/bin $pkg/bin $pkg/codex-path

    printenv CODEX_PACKAGE_MANIFEST_JSON > $pkg/codex-package.json

    zstd --decompress ${codexSource} -o $pkg/bin/codex
    zstd --decompress ${codeModeHostSource} -o $pkg/bin/codex-code-mode-host
    chmod +x $pkg/bin/codex $pkg/bin/codex-code-mode-host

    makeBinaryWrapper ${lib.getExe ripgrep} $pkg/codex-path/rg

    ln -s $pkg/bin/codex $out/bin/codex

    runHook postInstall
  '';

  postInstall =
    lib.optionalString stdenv.hostPlatform.isLinux ''
      makeBinaryWrapper ${lib.getExe bubblewrap} $pkg/codex-path/bwrap
      install -Dm755 /dev/null $pkg/codex-resources/bwrap
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
