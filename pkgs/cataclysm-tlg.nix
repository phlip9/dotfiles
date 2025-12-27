{
  SDL2,
  SDL2_image,
  SDL2_mixer,
  SDL2_ttf,
  cataclysmDDA,
  fetchFromGitHub,
  fetchzip,
  freetype,
  gettext,
  iconv,
  lib,
  libX11,
  makeBinaryWrapper,
  pkg-config,
  stdenv,
  stdenvNoCC,
  zlib,
}:

let
  # Unwrapped build of Cataclysm: The Last Generation
  unwrapped = stdenv.mkDerivation (final: {
    pname = "cataclysm-tlg";
    version = "1.0-2025-12-22-1410";

    src = fetchFromGitHub {
      owner = "Cataclysm-TLG";
      repo = "Cataclysm-TLG";
      tag = "cataclysm-tlg-${final.version}";
      hash = "sha256-SMXfusQnIE0Ehwtfiy8QJ0Q8qXp4ETVuyxrCa6N9xj4=";
    };

    postPatch = ''
      substituteInPlace Makefile \
        --replace-fail "-Werror -Wall -Wextra" ""
    '';

    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [
      gettext
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

    makeFlags = [
      "ASTYLE=0"
      "CURSES=0"
      "DYNAMIC_LINKING=1"
      "LINTJSON=0"
      "LOCALIZE=0"
      "PREFIX=$(out)"
      "RELEASE=1"
      "SOUND=1"
      "TESTS=0"
      "TILES=1"
      "USE_XDG_DIR=1"
      "VERSION=${final.version}"
    ];

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

    # Wrap and rename binary, pointing to correct --basepath
    mv $out/bin/cataclysm-tlg-tiles $out/bin/.cataclysm-tiles
    makeWrapper $out/bin/.cataclysm-tiles $out/bin/cataclysm-tlg \
      --add-flags "--basepath $out"

    runHook postInstall
  '';

  passthru = {
    inherit mods;
  };
}
