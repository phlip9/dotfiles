{
  appimageTools,
  electron,
  fetchurl,
  lib,
  libxt,
  libxtst,
  makeBinaryWrapper,
  nix-update-script,
  stdenv,
  xdg-utils,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "exiled-exchange-2";
  version = "0.15.8";

  src = fetchurl {
    url = "https://github.com/Kvan7/Exiled-Exchange-2/releases/download/v${finalAttrs.version}/Exiled-Exchange-2-${finalAttrs.version}.AppImage";
    hash = "sha256-xmEvKJkRFJokzOa/6qRqT4+QKfnfjIoAfqP+oDqyxH8=";
  };

  passthru = {
    appImageContents = appimageTools.extract {
      inherit (finalAttrs) pname src version;
    };

    updateScript = nix-update-script { };
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  # NOTE(phlip9): only include en-US locale to reduce space consumption by
  # ~40 MiB.
  installPhase = ''
    runHook preInstall
    mkdir -p \
      $out/bin \
      $out/share/exiled-exchange-2/locales \
      $out/share/applications

    cp -a \
      ${finalAttrs.passthru.appImageContents}/resources \
      $out/share/exiled-exchange-2
    cp -a \
      ${finalAttrs.passthru.appImageContents}/locales/en-US.pak \
      $out/share/exiled-exchange-2/locales/
    cp -a \
      ${finalAttrs.passthru.appImageContents}/exiled-exchange-2.desktop \
      $out/share/applications/
    cp -a ${finalAttrs.passthru.appImageContents}/usr/share/icons $out/share

    substituteInPlace $out/share/applications/exiled-exchange-2.desktop \
      --replace-fail 'Exec=AppRun' 'Exec=exiled-exchange-2'

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${lib.getExe electron} $out/bin/exiled-exchange-2 \
      --add-flag "$out/share/exiled-exchange-2/resources/app.asar" \
      --add-flag '--ozone-platform=x11' \
      --add-flag '--no-overlay' \
      --add-flag '--no-updates' \
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}" \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libxtst
          libxt
        ]
      }"
  '';

  meta = {
    description = "Path of Exile 2 trading app for price checking";
    homepage = "https://github.com/Kvan7/Exiled-Exchange-2";
    changelog = "https://github.com/Kvan7/Exiled-Exchange-2/releases/tag/v${finalAttrs.version}";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ phlip9 ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "exiled-exchange-2";
  };
})
