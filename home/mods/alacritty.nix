{ ... }:
{
  home.alacritty.enable = true;
  home.alacritty.settings = {
    import = [
      toString ../../alacritty.yml
    ];
  };
}
