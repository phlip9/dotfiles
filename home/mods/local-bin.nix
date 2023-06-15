# random scripts we link into ~/.local/bin from dotfiles/bin
{pkgs, ...}: {
  home.file.".local/bin/picolispfmt".source = ../../bin/picolispfmt;

  home.file.".local/bin/traceexec.d" = {
    enable = pkgs.stdenv.isDarwin;
    source = ../../bin/traceexec.d;
  };
}
