# Update with `just phlippkgs-update antigravity-cli`
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
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

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isElf [
    autoPatchelfHook
  ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 antigravity $out/bin/agy

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
