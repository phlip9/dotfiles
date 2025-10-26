# Cataclysm - Dark Days Ahead (game)
{
  pkgs,
  lib,
  ...
}:
let
  cddaLib = {
    inherit (pkgs.cataclysmDDA)
      attachPkgs
      buildMod
      buildSoundPack
      buildTileSet
      pkgs
      wrapCDDA
      ;
  };

  cdda-pre-fix = pkgs.cataclysm-dda-git.override rec {
    version = "2024-04-04-2115";
    rev = "cdda-experimental-${version}";
    sha256 = "sha256-WvEbhCUyn7IYdzDQqqnV1m0CWJCuZx3sK/j+KLWrHH4=";
    useXdgDir = true;
  };

  cdda-no-mod = cdda-pre-fix.overrideAttrs (super: {
    # patch doesn't cleanly apply anymore
    patches = [ ];

    passthru = super.passthru // {
      pkgs = pkgs.override { build = cdda-no-mod; };
      withMods = cddaLib.wrapCDDA cdda-no-mod;
    };
  });

  customMods =
    self: super:
    lib.recursiveUpdate super {
      soundpack.CC-Sounds = cddaLib.buildSoundPack rec {
        modName = "CC-Sounds";
        version = "2024-01-17";
        src = pkgs.fetchzip {
          url = "https://github.com/Fris0uman/CDDA-Soundpacks/releases/download/${version}/CC-Sounds.zip";
          hash = "sha256-IkqdUZyfK50YV4dHapEjjBm/SVhOjZk0jiMKCo5h7gQ=";
        };
        modRoot = "CC-Sounds";
      };
    };

  cdda = (cddaLib.attachPkgs cddaLib.pkgs cdda-no-mod).withMods (
    mods: with mods.extend customMods; [
      soundpack.CC-Sounds
    ]
  );
in
{
  home.packages = [ cdda ];
}
