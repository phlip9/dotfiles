# Cataclysm - Dark Days Ahead (game)
{
  pkgs,
  lib,
  ...
}: let
  cddaLib = {
    inherit
      (pkgs.cataclysmDDA)
      attachPkgs
      buildMod
      buildSoundPack
      buildTileSet
      pkgs
      wrapCDDA
      ;
  };

  cdda-pre-fix = pkgs.cataclysm-dda-git.override {
    version = "2023-12-28";
    rev = "3f44fb3ebf533a3475e0a146b6bd22353e7c7b65";
    sha256 = "sha256-IsNj+R24lBCO66ZdrJla7Vl4l5lsfKnGHVO6ljpZHoA=";
    useXdgDir = true;
  };

  cdda-no-mod = cdda-pre-fix.overrideAttrs (super: {
    # patch doesn't cleanly apply anymore
    patches = [];

    passthru =
      super.passthru
      // {
        pkgs = pkgs.override {build = cdda-no-mod;};
        withMods = cddaLib.wrapCDDA cdda-no-mod;
      };
  });

  customMods = self: super:
    lib.recursiveUpdate super {
      soundpack.CC-Sounds = cddaLib.buildSoundPack {
        modName = "CC-Sounds";
        version = "2023-12-10";
        src = pkgs.fetchzip {
          url = "https://github.com/Fris0uman/CDDA-Soundpacks/releases/download/2023-12-10/CC-Sounds.zip";
          hash = "sha256-X0da9cs60sr5jq4TPTMkNQAHAjcu1gPagJyLDJ7HOe0=";
        };
      };
    };

  cdda = (cddaLib.attachPkgs cddaLib.pkgs cdda-no-mod).withMods (mods:
    with mods.extend customMods; [
      soundpack.CC-Sounds
    ]);
in {
  home.packages = [cdda];
}
