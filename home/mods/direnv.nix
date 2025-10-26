# [`direnv`](https://github.com/direnv/direnv)
#
# loads a project-specific environment upon entering a project directory.
#
# * load environment variables
# * run `nix develop` to for isolated per-project tools
# * setup secrets for deployment
{ ... }:
{
  programs.direnv = {
    enable = true;

    enableBashIntegration = true;

    nix-direnv.enable = true;
  };
}
