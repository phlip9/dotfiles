# dotfiles flake.nix
#
# This file is the entry point for describing the nix `home-manager`
# configuration.
#
# ### Helpful Nix Links
#
# * nixpkgs search:
#   <https://search.nixos.org/packages>
#
# * home-manager options search:
#   <https://mipmip.github.io/home-manager-option-search>
#
# * `builtins` and `nixpkgs.lib` search:
#   <https://teu5us.github.io/nix-lib.html>
#
#   (not sure how up-to-date it is... looks like it can be regenerated?
#   see here to generate <https://github.com/teu5us/nix-lib-html-reference>)
#
# ### `flake.nix` schema
#
# The NixOS wiki has ok human-readable docs on `flake.nix`:
# <https://nixos.wiki/wiki/Flakes#Flake_schema>
#
# For the most complete picture, you can also try to decipher the `nix flake check`
# implementation
# [`nix/flake.cc::CmdFlakeCheck::run`](https://github.com/NixOS/nix/blob/master/src/nix/flake.cc#L502).
{
  description = "Home Manager configuration of phlip9";

  # # configures a flake-specific nix.conf
  # #
  # # `nix.conf` schema: <https://nixos.org/manual/nix/stable/command-ref/conf-file.html>
  # nixConfig = {
  #   bash-prompt-prefix = "(nix)";
  # };

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
    # pkgs = nixpkgs.legacyPackages."x86_64-linux";

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

      check = true;
    };

    homeConfigurations."phliptop-mbp" = home-manager.lib.homeManagerConfiguration rec {
      pkgs = nixpkgs.legacyPackages."aarch64-darwin";
      lib = pkgs.lib;
      modules = [./home/phliptop-mbp.nix];

      # Use `extraSpecialArgs` to pass through arguments from the flake.nix to
      # the home-manager modules.
      extraSpecialArgs = {
        inputs = inputs;
      };

      check = true;
    };

    # The *.nix file formatter.
    formatter = forEachPkgs (pkgs: pkgs.alejandra);

    devShells = forEachPkgs (pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          # Uncompromising nix code formatter
          # <https://github.com/kamadorueda/alejandra>
          pkgs.alejandra

          # Static analysis tool for shell scripts
          # <https://github.com/koalaman/shellcheck>
          pkgs.shellcheck

          # Just a command runner
          # <https://github.com/casey/just>
          pkgs.just
        ];
      };
    });
  };
}
