{config, ...}: let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;
in {
  xdg.configFile."gdb/gdbinit".source = mkOutOfStoreSymlink "${dotfilesDir}/gdbinit";
}
