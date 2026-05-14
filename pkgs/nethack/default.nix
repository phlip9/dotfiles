# Vendored while we wait for this PR and these edits to land:
# - <https://gitlab.com/liferooter/the-config/-/blob/main/packages/nethack/default.nix>
# - <https://github.com/NixOS/nixpkgs/pull/516017>
# - <https://github.com/Feyorsh/nixpkgs/blob/f57572d8d6eea3ee523f954b3e9a880820de5f2c/pkgs/by-name/ne/nethack/package.nix>
{
  stdenv,
  lib,
  fetchurl,
  groff,
  ncurses,
  gzip,
  gnugrep,
  libxaw,
  libxext,
  libxpm,
  bdftopcf,
  mkfontdir,
  pkg-config,
  qt5,
  copyDesktopItems,
  makeDesktopItem,
  x11Support ? false,
  qtSupport ? false,
  ...
}:

let
  hint =
    if stdenv.hostPlatform.isLinux then
      "linux.500"
    else if stdenv.hostPlatform.isDarwin then
      "macos.500"
    else
      "unix";
in

assert lib.assertMsg stdenv.hostPlatform.isUnix
  "Unsupported platform for NetHack: ${stdenv.hostPlatform.system}";

stdenv.mkDerivation (finalAttrs: {
  version = "5.0.0";
  pname = "nethack";

  src = fetchurl {
    url = "https://nethack.org/download/${finalAttrs.version}/nethack-${
      lib.replaceStrings [ "." ] [ "" ] finalAttrs.version
    }-src.tgz";
    sha256 = "sha256-KVm3iGqsdhhbkK6gyfgNFDQ/YE3grpaz3Sp2D3qzvek=";
  };

  patches = [
    # mod: prefer left-hand keys for inventory etc
    ./left-hand-selection-keys.patch
  ];

  buildInputs = [
    ncurses
  ]
  ++ lib.optionals x11Support [
    libxaw
    libxext
    libxpm
  ]
  ++ lib.optionals qtSupport [
    gzip
    qt5.qtbase.bin
    qt5.qtmultimedia.bin
  ];

  nativeBuildInputs = [
    copyDesktopItems
    groff
    pkg-config
  ]
  ++ lib.optionals x11Support [
    mkfontdir
    bdftopcf
  ]
  ++ lib.optionals qtSupport [
    mkfontdir
    qt5.qtbase.dev
    qt5.qtmultimedia.dev
    qt5.wrapQtAppsHook
    bdftopcf
  ];

  NIX_CFLAGS_COMPILE = "-DVAR_PLAYGROUND=getenv(\"NETHACKVARDIR\")";

  makeFlags = [
    "PREFIX=$(out)"
    "HACKDIR=$(out)/lib/nethack"
    "VARDIR=$(out)/lib/nethack/vardir"
    "WANT_WIN_TTY=1"
    "WANT_WIN_CURSES=1"
    "WANT_DEFAULT=curses"
  ]
  ++ lib.optionals x11Support [
    "WANT_WIN_X11=1"
    "WANT_DEFAULT=X11"
  ]
  ++ lib.optionals qtSupport [
    "QTDIR=${qt5.qtbase.dev}"
    "WANT_WIN_QT5=1"
    "WANT_DEFAULT=Qt"
  ];

  postPatch = ''
    sed -i sys/unix/hints/${hint} \
      -e 's:/bin/gzip:${lib.getExe gzip}:g' \
      -e '/^SHELLDIR =/d' \
      -e 's:PKG_CONFIG_PATH=[^ ]*::g' \
      -e '/^GIT_/d'

    sed -i sys/unix/sysconf \
      -e 's:/bin/grep:${lib.getExe gnugrep}:g' \
      -e '/^GDBPATH=/d' \
      -e '/^PANICTRACE_GDB=/s:1:0:' \
      -e '/^WIZARDS=/s:=.*:=*:'

    ${lib.optionalString x11Support ''
      sed -i include/config.h \
        -e '/define ENHANCED_SYMBOLS/d'
    ''}
  '';

  configurePhase = ''
    pushd sys/unix
    sh setup.sh hints/${hint}
    popd
  '';

  preBuild =
    let
      lua548 = fetchurl {
        url = "https://www.lua.org/ftp/lua-5.4.8.tar.gz";
        hash = "sha256-TxjdrhVOeT5G7qtyfFnvHAwMK3ROe5QhlxDXb1MGKa4=";
      };
    in
    ''
      mkdir -p lib
      tar zxf ${lua548} -C lib
    '';

  # Upstream make races generated Lua headers against C compilation.
  enableParallelBuilding = false;

  preFixup = lib.optionalString qtSupport ''
    wrapQtApp "$out/lib/nethack/nethack"
  '';

  postInstall = ''
    mkdir $out/bin

    cat <<EOF >$out/bin/nethack
    #! ${stdenv.shell} -e
    export NETHACKVARDIR="\$HOME/.local/share/nethack"

    if [ ! -e "\$NETHACKVARDIR" ]; then
      mkdir -p "\$NETHACKVARDIR"
      cp -r $out/lib/nethack/vardir/* "\$NETHACKVARDIR"
      chmod -R +w "\$NETHACKVARDIR"/*
    fi

    exec $out/lib/nethack/nethack \$@
    EOF

    chmod +x $out/bin/nethack
  '';

  desktopItems = lib.optional (x11Support || qtSupport) (makeDesktopItem {
    name = "NetHack";
    exec = finalAttrs.pname;
    icon = "nethack";
    desktopName = "NetHack";
    comment = finalAttrs.meta.description;
    categories = [
      "Game"
      "ActionGame"
    ];
  });

  meta = {
    description = "Rogue-like game";
    homepage = "http://nethack.org/";
    license = lib.licenses.ngpl;
    platforms = lib.platforms.unix;
    maintainers = with lib.maintainers; [
      # olduser101
      liferooter
    ];
    mainProgram = "nethack";
  };
})
