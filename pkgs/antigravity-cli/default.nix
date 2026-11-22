# Update with `just phlippkgs-update antigravity-cli`
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeBinaryWrapper,
  ripgrep,
  versionCheckHook,
}:
let
  stdenv = stdenvNoCC;
  manifest = lib.importJSON ./manifest.json;
  # nix system -> upstream manifest platform key
  platformKey =
    {
      "aarch64-darwin" = "darwin-arm";
      "x86_64-linux" = "linux-x64";
    }
    .${stdenv.hostPlatform.system};
  platformManifestEntry = manifest.platforms.${platformKey};
in
stdenv.mkDerivation {
  pname = "antigravity-cli";
  inherit (manifest) version;

  src = fetchurl {
    inherit (platformManifestEntry) url sha512;
  };

  # tarball contains a single top-level `antigravity` binary
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    makeBinaryWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isElf [ autoPatchelfHook ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 antigravity $out/bin/agy

    # Disable the background self-updater; nix manages updates. Upstream only
    # honors `true` here, not `1`. Without this, the updater still skips the
    # read-only /nix/store, but only after a warning in every session log.
    #
    # Also use nixpkgs `rg` over the embedded ripgrep, which agy otherwise
    # extracts into ~/.cache and execs from there.
    #
    # Also run the TUI inline instead of in the alternate screen, which breaks
    # terminal scrollback. `--settings` is a session-only overlay on top of
    # settings.json and works before any subcommand. A later user-supplied
    # `--settings` replaces this one wholesale (no merge).
    wrapProgram $out/bin/agy \
      --set AGY_CLI_DISABLE_AUTO_UPDATE true \
      --set ANTIGRAVITY_DISABLE_EMBEDDED_RIPGREP true \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
      --add-flag --settings \
      --add-flag '{"altScreenMode":"never"}'

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Google Antigravity terminal agent client";
    homepage = "https://antigravity.google";
    changelog = "https://antigravity.google/changelog";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    mainProgram = "agy";
  };
}
