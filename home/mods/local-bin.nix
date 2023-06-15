# Local random scripts we link into ~/.local/bin from dotfiles/bin
{
  config,
  pkgs,
  ...
}: let
  local-bin = "${config.home.homeDirectory}/.local/bin";
in {
  home.file."picolispfmt" = {
    source = ../../bin/picolispfmt;
    target = "${local-bin}/picolispfmt";
  };

  home.file."traceexec.d" = {
    enable = pkgs.stdenv.isDarwin;
    source = ../../bin/traceexec.d;
    target = "${local-bin}/traceexec.d";
  };
}
