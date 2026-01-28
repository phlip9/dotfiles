# Packaging notes:
# - The omnara binary is really a bun single-file executable. You can read the
#   minified typescript source by dumping the binary's strings lol... This is
#   how I found the OMNARA_NO_UPDATE env.
# - Manual patchelf appears to corrupt the binary somehow.

{
  autoPatchelfHook,
  fetchurl,
  lib,
  makeBinaryWrapper,
  stdenvNoCC,
  versionCheckHook,
}:
let
  hostPlatform = stdenvNoCC.hostPlatform;
  sources = lib.importJSON ./sources.json;
  source = sources.${hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "omnara";
  inherit (source) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  strictDeps = true;
  nativeBuildInputs = [
    makeBinaryWrapper
  ]
  ++ lib.optionals hostPlatform.isLinux [
    autoPatchelfHook
  ];

  installPhase = ''
    runHook preInstall

    install -Dm 755 $src $out/bin/omnara

    wrapProgram $out/bin/omnara \
      --set OMNARA_NO_UPDATE 1 \
      --set OMNARA_RELEASE_URL "http://localhost:6969"

    runHook postInstall
  '';

  dontStrip = true;

  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Omnara CLI";
    homepage = "https://omnara.com";
    mainProgram = "omnara";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}
