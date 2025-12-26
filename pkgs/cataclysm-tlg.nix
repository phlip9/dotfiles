{
  SDL2,
  SDL2_image,
  SDL2_mixer,
  SDL2_ttf,
  cataclysmDDA,
  cmake,
  fetchFromGitHub,
  fetchzip,
  freetype,
  gettext,
  iconv,
  lib,
  libX11,
  makeBinaryWrapper,
  ninja,
  pkg-config,
  runtimeShell,
  stdenv,
  stdenvNoCC,
  zlib,
}:

let
  # Unwrapped build of Cataclysm: The Last Generation
  unwrapped = stdenv.mkDerivation (finalAttrs: {
    pname = "cataclysm-tlg";
    version = "1.0-2025-12-22-1410";

    src = fetchFromGitHub {
      owner = "Cataclysm-TLG";
      repo = "Cataclysm-TLG";
      tag = "cataclysm-tlg-${finalAttrs.version}";
      hash = "sha256-SMXfusQnIE0Ehwtfiy8QJ0Q8qXp4ETVuyxrCa6N9xj4=";
    };

    postPatch = ''
      substituteInPlace data/CMakeLists.txt \
        --replace-fail "screenshots" ""

      substituteInPlace CMakeLists.txt \
        --replace-fail "-Wmissing-noreturn \\" "-Wno-error=missing-noreturn \\"
    '';

    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [
      cmake
      gettext
      ninja
      pkg-config
    ];

    buildInputs = [
      SDL2
      SDL2_image
      SDL2_mixer
      SDL2_ttf
      freetype
      gettext
      libX11
      zlib
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      iconv
    ];

    enableParallelBuilding = true;

    cmakeFlags = [
      (lib.cmakeBool "CURSES" false)
      (lib.cmakeBool "DYNAMIC_LINKING" true)
      (lib.cmakeBool "LOCALIZE" true)
      (lib.cmakeBool "RELEASE" true)
      (lib.cmakeBool "SOUND" true)
      (lib.cmakeBool "TESTS" false)
      (lib.cmakeBool "TILES" true)
      (lib.cmakeBool "USE_HOME_DIR" false)
      (lib.cmakeBool "USE_PREFIX_DATA_DIR" true)
      (lib.cmakeBool "USE_XDG_DIR" true)
      (lib.cmakeFeature "GIT_VERSION" finalAttrs.version)
      (lib.cmakeFeature "LANGUAGES" "da")
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      "-DICONV_LIBRARIES=${lib.getLib iconv}/lib/libiconv.dylib"
    ];

    postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
      app=$out/Applications/Cataclysm.app

      # The cmake build is out-of-source, so read assets from the original source tree.
      install -D -m 444 "$src/build-data/osx/Info.plist" -t "$app/Contents"
      install -D -m 444 "$src/build-data/osx/AppIcon.icns" -t "$app/Contents/Resources"

      mkdir $app/Contents/MacOS
      launcher=$app/Contents/MacOS/Cataclysm.sh
      cat << EOF > $launcher
      #!${runtimeShell}
      $out/bin/cataclysm-tiles
      EOF

      chmod 555 $launcher
    '';

    meta = {
      mainProgram = "cataclysm-tiles";
    };
  });

  # CC-Sounds soundpack for Cataclysm
  CC-Sounds = cataclysmDDA.buildSoundPack rec {
    modName = "CC-Sounds";
    version = "2025-11-15";
    src = fetchzip {
      url = "https://github.com/Fris0uman/CDDA-Soundpacks/releases/download/${version}/CC-Sounds.zip";
      hash = "sha256-esMFyijsCWldF2iBCoBxy6CVe+Ld03z/on4MiIs5V+Y=";
    };
  };

  mods = {
    inherit CC-Sounds;
  };
in

# Wrapped derivation that copies in mods and points to the correct --datadir
stdenvNoCC.mkDerivation {
  inherit (unwrapped) pname version;

  phases = [ "installPhase" ];

  nativeBuildInputs = [ makeBinaryWrapper ];

  modsList = builtins.attrValues mods;
  unwrapped = unwrapped;

  installPhase = ''
    runHook preInstall

    # Copy full unwrapped build
    cp --recursive --reflink=auto "$unwrapped" $out
    chmod --recursive u+w $out
    rm -rf $out/Applications

    # Copy in mods
    for mod in $modsList; do
      cp --recursive --reflink=auto --force $mod/share/cataclysm-*/* $out/share/cataclysm-tlg/
    done

    # Wrap and rename binary, pointing to correct --datadir
    mv $out/bin/cataclysm-tiles $out/bin/.cataclysm-tiles
    makeWrapper $out/bin/.cataclysm-tiles $out/bin/cataclysm-tlg \
      --add-flags "--datadir $out/share/cataclysm-tlg/"

    runHook postInstall
  '';

  passthru = {
    inherit mods;
  };
}
