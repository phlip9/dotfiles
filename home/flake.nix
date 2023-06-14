{
  description = "Home Manager configuration of phlip9";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... } @ inputs: {

    homeConfigurations."phlipdesk" = home-manager.lib.homeManagerConfiguration rec {
      pkgs = nixpkgs.legacyPackages."x86_64-linux";
      lib = pkgs.lib;
      modules = [ ./phlipdesk.nix ];

      # Use `extraSpecialArgs` to pass through arguments from the flake.nix to
      # the home-manager modules.
      extraSpecialArgs = {
        inputs = inputs;
      };

      # idk what this option does
      check = true;
    };

  };
}
