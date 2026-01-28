# Neovim home-manager module: install nvim package, configure dotfile symlinks,
# and generate lua LSP settings for local nvim plugin development.
#
# See also: pkgs/nvim/default.nix
{
  config,
  phlipPkgs,
  ...
}:
let
  mkOutOfStoreSymlink = config.lib.file.mkOutOfStoreSymlink;
  dotfilesDir = config.home.dotfilesDir;

  nvim = phlipPkgs.nvim;
in
{
  home.packages = [
    nvim
  ];

  # use nvim as our man pager
  # - set `MANWIDTH=999` b/c man pages are hardwrapped at a few columns too
  #   much. "disable" hardwrap with this env.
  programs.bash.initExtra = ''
    export MANPAGER="${nvim}/bin/nvim +Man!"
    export MANWIDTH=999
  '';

  # symlink ~/.config/nvim to `dotfiles/nvim` dir.
  xdg.configFile."nvim".source = mkOutOfStoreSymlink "${dotfilesDir}/nvim";

  # Configure the lua LSP for local nvim plugin development.
  home.file."dev/dotfiles/.vim/coc-settings.json".source =
    "${nvim.dotfilesCocSettingsFile}";

  # .luarc.json for CLI lua-language-server --check (used by `just nvim-lint`)
  home.file."dev/dotfiles/.luarc.json".source = "${nvim.dotfilesLuarcJsonFile}";
}
