{ config, ... }:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in
{
  xdg.configFile."noctalia".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/noctalia";

  xdg.configFile."fuzzel".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/fuzzel";

  xdg.configFile."gtk-3.0/gtk.css".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/gtk-3.0/gtk.css";
  xdg.configFile."gtk-3.0/colors".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/gtk-3.0/colors";

  xdg.configFile."gtk-4.0/gtk.css".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/gtk-4.0/gtk.css";
  xdg.configFile."gtk-4.0/colors".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/gtk-4.0/colors";

  xdg.configFile."qt5ct".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/qt5ct";
  xdg.configFile."qt6ct".source =
    mkOutOfStoreSymlink "${dotfilesDir}/config/qt6ct";
}
