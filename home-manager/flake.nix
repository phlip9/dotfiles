{
  description = "Home Manager configuration of phlip9";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations."phlip9" = home-manager.lib.homeManagerConfiguration {
        pkgs = pkgs;
        lib = pkgs.lib;
        check = true;

        # Specify your home configuration modules here:
        modules = [ ./home.nix ];

        # Use `extraSpecialArgs` to pass through arguments to `home.nix`.
        extraSpecialArgs = {};
      };
    };
}
