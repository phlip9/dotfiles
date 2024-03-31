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

  cdda-no-mod = pkgs.cataclysm-dda;

  customMods = self: super:
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

  cdda = (cddaLib.attachPkgs cddaLib.pkgs cdda-no-mod).withMods (mods:
    with mods.extend customMods; [
      soundpack.CC-Sounds
    ]);
in {
  home.packages = [cdda];
}
