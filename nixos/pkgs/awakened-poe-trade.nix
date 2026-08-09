{
  lib,
  fetchurl,
  stdenv,
  appimageTools,
  makeBinaryWrapper,
  electron,
  libxtst,
  libxt,

  nix-update-script,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "awakened-poe-trade";
  version = "3.29.104";

  src = fetchurl {
    url = "https://github.com/SnosMe/awakened-poe-trade/releases/download/v${finalAttrs.version}/Awakened-PoE-Trade-${finalAttrs.version}.AppImage";
    hash = "sha256-ApZwjy1tJwUtevLA7QY8/zrnHI5Tt4aXMpTo+5VWGUg=";
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

  # NOTE(phlip9): only include en-US locale to reduce space consumption by ~40 MiB
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/awakened-poe-trade/locales $out/share/applications

    cp -a ${finalAttrs.passthru.appImageContents}/resources $out/share/awakened-poe-trade
    cp -a ${finalAttrs.passthru.appImageContents}/locales/en-US.pak $out/share/awakened-poe-trade/locales/
    cp -a ${finalAttrs.passthru.appImageContents}/awakened-poe-trade.desktop $out/share/applications/
    cp -a ${finalAttrs.passthru.appImageContents}/usr/share/icons $out/share

    substituteInPlace $out/share/applications/awakened-poe-trade.desktop \
      --replace-fail 'Exec=AppRun' 'Exec=awakened-poe-trade'

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${lib.getExe electron} $out/bin/awakened-poe-trade \
      --add-flag "$out/share/awakened-poe-trade/resources/app.asar" \
      --add-flag '--ozone-platform=x11' \
      --add-flag '--no-overlay' \
      --add-flag '--no-updates' \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [
          libxtst
          libxt
        ]
      }"
  '';

  meta = {
    description = "Path of Exile trading app for price checking";
    homepage = "https://github.com/SnosMe/awakened-poe-trade";
    changelog = "https://github.com/SnosMe/awakened-poe-trade/releases/tag/v${finalAttrs.version}";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      mreichardt95
    ];
    platforms = with lib.platforms; linux;
    mainProgram = "awakened-poe-trade";
  };
})
