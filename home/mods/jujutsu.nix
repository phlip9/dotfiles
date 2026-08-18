# jujutsu - Git-compatible DVCS that is both simple and powerful
{
  lib,
  ...
}:

{
  programs.jujutsu = {
    enable = true;

    settings = {
      user = {
        name = lib.mkDefault "Philip Kannegaard Hayes";
        email = lib.mkDefault "philiphayes9@gmail.com";
      };
    };
  };
}
