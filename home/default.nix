{
  hm,
  phlipPkgs,
  pkgs,
  pkgsYubikey,
  sources,
}:
{
  phlipdesk = hm.lib.homeManagerConfiguration {
    pkgs = pkgs;
    modules = [ ./phlipdesk.nix ];
    extraSpecialArgs = {
      # force hm to use one pkgs eval to reduce eval time by 600ms
      inherit phlipPkgs pkgs;
      inputs = sources;
      pkgsUnfree = pkgs;
      pkgsYubikey = pkgs;
    };
  };

  phliptop-nitro = hm.lib.homeManagerConfiguration {
    pkgs = pkgs;
    modules = [ ./phliptop-nitro.nix ];
    extraSpecialArgs = {
      # force hm to use one pkgs eval to reduce eval time by 600ms
      inherit phlipPkgs pkgs pkgsYubikey;
      inputs = sources;
      pkgsUnfree = pkgs;
    };
  };

  phlipnixos = hm.lib.homeManagerConfiguration {
    pkgs = pkgs;
    modules = [ ./phlipnixos.nix ];
    extraSpecialArgs = {
      # force hm to use one pkgs eval to reduce eval time by 600ms
      inherit phlipPkgs pkgs;
      inputs = sources;
      pkgsUnfree = pkgs;
      pkgsYubikey = pkgs;
    };
  };

  phliptop-mbp = hm.lib.homeManagerConfiguration {
    pkgs = pkgs;
    modules = [ ./phliptop-mbp.nix ];
    extraSpecialArgs = {
      # force hm to use one pkgs eval to reduce eval time by 600ms
      inherit phlipPkgs pkgs;
      inputs = sources;
      pkgsUnfree = pkgs;
      pkgsYubikey = pkgs;
    };
  };
}
