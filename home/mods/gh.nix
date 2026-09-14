{ phlipPkgs, ... }:
{
  programs.gh = {
    enable = true;
    extensions = [ phlipPkgs.gh-stack ];
  };
}
