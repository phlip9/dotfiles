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
    version = "2024-01-11";
    rev = "c51a21b458e962d17f3bd322c38be0260a627f5e";
    sha256 = "sha256-RTKMAN5UcuDtwXwXweu8TN/q9Es04j5FoNMy4Zltgcs=";
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

      # Remove this after upstream cdda repo gets the update
      mod.Sky-Islands = cddaLib.buildMod {
        modName = "Sky-Islands (Milestone 1)";
        version = "0.3";
        src = pkgs.fetchFromGitHub {
          owner = "TGWeaver";
          repo = "CDDA-Sky-Islands";
          rev = "4d06105b77f69eb492e78c9aedf2ffdd15d1b42e";
          hash = "sha256-MHTKoYqG4MhUFRqoNeB7X6HCd3rHRI0JL17jfkWE5e4=";
        };
      };
    };

  cdda = (cddaLib.attachPkgs cddaLib.pkgs cdda-no-mod).withMods (mods:
    with mods.extend customMods; [
      soundpack.CC-Sounds
      mod.Sky-Islands
    ]);
in {
  home.packages = [cdda];
}
