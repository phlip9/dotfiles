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
  # Without it, `codex` doesn't recognize the package layout below and reports
  # its runtime build version (ex: exec-server metadata) as 0.0.0.
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
  # and expects upstream's standalone package layout:
  #
  # - codex-package.json
  # - bin/codex
  # - bin/codex-code-mode-host
  # - codex-path/rg
  # - codex-path/bwrap (linux only)
  #
  # `codex` prepends `codex-path` to its own PATH at startup, so the sandbox
  # helper and agent shells all find nixpkgs `rg` and `bwrap` via the small
  # exec wrappers there.
  #
  # Upstream's layout also ships a bundled `codex-resources/bwrap`, but `codex`
  # only falls back to it when there's no `bwrap` on PATH. The app-server
  # daemon's package completeness check is the only thing that requires it,
  # and we disable the daemon below.
  installPhase = ''
    runHook preInstall

    pkg=$out/libexec/codex
    mkdir -p $out/bin $pkg/bin $pkg/codex-path

    printenv CODEX_PACKAGE_MANIFEST_JSON > $pkg/codex-package.json

    zstd --decompress ${codexSource} -o $pkg/bin/codex
    zstd --decompress ${codeModeHostSource} -o $pkg/bin/codex-code-mode-host
    chmod +x $pkg/bin/codex $pkg/bin/codex-code-mode-host

    makeBinaryWrapper ${lib.getExe ripgrep} $pkg/codex-path/rg

    # Since 0.159, the interactive TUI auto-starts a persistent, detached
    # app-server daemon by default. The daemon also runs an updater loop that
    # periodically fetches and runs `chatgpt.com/codex/install.sh` to install
    # a new codex into `$CODEX_HOME/packages/`, bypassing nix. Force the
    # `daemon_auto_start` feature off so the TUI uses its embedded app-server
    # instead. `--disable` is a global flag, so it's valid before any
    # subcommand. CLI flags override `config.toml`.
    #
    # Also run the TUI inline instead of in the alternate screen, which breaks
    # terminal scrollback. `--no-alt-screen` is TUI-only and would break
    # subcommands like `codex exec` or `codex app-server`, so set the
    # equivalent `tui.alternate_screen` config via the global `-c` instead.
    makeBinaryWrapper $pkg/bin/codex $out/bin/codex \
      --add-flags "--disable daemon_auto_start" \
      --add-flags "-c tui.alternate_screen=never"

    runHook postInstall
  '';

  postInstall =
    lib.optionalString stdenv.hostPlatform.isLinux ''
      makeBinaryWrapper ${lib.getExe bubblewrap} $pkg/codex-path/bwrap
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
