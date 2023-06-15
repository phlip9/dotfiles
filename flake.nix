{
  description = "Home Manager configuration of phlip9";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
  } @ inputs: let
    # supported systems
    systems = ["aarch64-darwin" "x86_64-linux"];

    # Example:
    # > genAttrs [ "bob" "joe" ] (name: "hello ${name}")
    # { bob = "hello bob"; joe = "hello joe" }
    genAttrs = nixpkgs.lib.genAttrs;

    # forEachSystem :: (String -> AttrSet) -> AttrSet
    #
    # Example:
    # > forEachSystem (system: { a = 123; b = "cool ${system}"; })
    # {
    #   "aarch64-darwin" = {
    #     a = 123;
    #     b = "cool aarch64-darwin";
    #   };
    #   "x86_64-linux" = {
    #     a = 123;
    #     b = "cool x86_64-linux";
    #   };
    # }
    forEachSystem = builder:
      genAttrs systems builder;

    # forEachPkgs :: (Nixpkgs -> AttrSet) -> AttrSet
    forEachPkgs = builder:
      forEachSystem (
        system:
          builder nixpkgs.legacyPackages.${system}
      );
  in {
    # TIP: uncomment this line to easily poke through the nixpkgs state in the
    # `nix repl` (use `:load-flake .` after opening the repl).
    #
    pkgs = nixpkgs.legacyPackages."x86_64-linux";

    # Re-export home-manager package so we can easily reference it on first-time
    # setup for a new machine.
    packages = forEachSystem (system: {
      home-manager = inputs.home-manager.packages.${system}.home-manager;
    });

    # home-manager configurations for different hosts

    homeConfigurations."phlipdesk" = home-manager.lib.homeManagerConfiguration rec {
      pkgs = nixpkgs.legacyPackages."x86_64-linux";
      lib = pkgs.lib;
      modules = [./home/phlipdesk.nix];

      # Use `extraSpecialArgs` to pass through arguments from the flake.nix to
      # the home-manager modules.
      extraSpecialArgs = {
        inputs = inputs;
      };

      # idk what this option does
      check = true;
    };

    # The *.nix file formatter.
    formatter = forEachPkgs (pkgs: pkgs.alejandra);

    devShells = forEachPkgs (pkgs: {
      default = pkgs.mkShell {
        buildInputs = [
          pkgs.alejandra
        ];
      };
    });
  };
}
