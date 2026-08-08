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
      inherit sources;
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
      inherit sources;
      pkgsUnfree = pkgs;
    };
  };

  phliptop-mbp = hm.lib.homeManagerConfiguration {
    pkgs = pkgs;
    modules = [ ./phliptop-mbp.nix ];
    extraSpecialArgs = {
      # force hm to use one pkgs eval to reduce eval time by 600ms
      inherit phlipPkgs pkgs;
      inherit sources;
      pkgsUnfree = pkgs;
      pkgsYubikey = pkgs;
    };
  };

  sauna = hm.lib.homeManagerConfiguration {
    pkgs = pkgs;
    modules = [ ./sauna.nix ];
    extraSpecialArgs = {
      inherit phlipPkgs pkgs;
      inherit sources;
      pkgsUnfree = pkgs;
      pkgsYubikey = pkgs;
    };
  };
}
