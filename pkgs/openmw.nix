# OpenMW - open morrowind game engine
{
  fetchzip,
  runCommandLocal,
}:
let
  pname = "openmw";
  version = "0.49.0-rc5";
in
runCommandLocal "${pname}-${version}"
  {
    # Use latest unstable binary release, since
    # 1. no nixGL issues
    # 2. nixpkgs uses old stable release
    # 3. many mods require unstable
    bins = fetchzip {
      pname = pname;
      version = version;
      url = "https://github.com/OpenMW/openmw/releases/download/openmw-49-rc5/openmw-0.49.0-Linux-64BitRC5.tar.gz";
      hash = "sha256-gsMHm66f3oAWAmMbTJZY86AV5C1jJiSJfaJAdo8Uhl0=";
    };
  }
  ''
    # link top-level binaries
    mkdir -p "$out/bin"
    ln -s \
      "$bins/bsatool" \
      "$bins/esmtool" \
      "$bins/niftest" \
      "$bins/openmw" \
      "$bins/openmw-bulletobjecttool" \
      "$bins/openmw-cs" \
      "$bins/openmw-essimporter" \
      "$bins/openmw-iniimporter" \
      "$bins/openmw-launcher" \
      "$bins/openmw-navmeshtool" \
      "$bins/openmw-wizard" \
      "$out/bin"

    # link desktop entry
    mkdir -p "$out/share/applications"
    ln -s "$bins/org.openmw.launcher.desktop" "$out/share/applications/org.openmw.launcher.desktop"

    # link desktop icon
    # TODO(phlip9): doesn't appear to work?
    mkdir -p "$out/share/icons/hicolor/256x256/apps"
    ln -s "$bins/openmw.png" "$out/share/icons/hicolor/256x256/apps/openmw.png"
  ''
