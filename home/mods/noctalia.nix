{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  xdg.configFile."noctalia".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/noctalia";

  xdg.configFile."gtk-3.0/gtk.css".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/gtk-3.0/gtk.css";
  xdg.configFile."gtk-4.0/gtk.css".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/gtk-4.0/gtk.css";
  xdg.configFile."qt5ct/colors/noctalia.conf".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/qt5ct/colors/noctalia.conf";
  xdg.configFile."qt6ct/colors/noctalia.conf".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/qt6ct/colors/noctalia.conf";

  xdg.configFile."fuzzel/themes/noctalia".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/fuzzel/themes/noctalia";
}
