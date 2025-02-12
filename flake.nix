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
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      # url = "github:nix-community/home-manager/release-24.05";
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...} @ inputs: let
    lib = inputs.nixpkgs.lib;

    # supported systems
    systems = ["aarch64-darwin" "x86_64-linux"];

    # genAttrs :: [ String ] -> (String -> Any) -> AttrSet
    #
    # ```
    # > genAttrs [ "bob" "joe" ] (name: "hello ${name}")
    # { bob = "hello bob"; joe = "hello joe" }
    # ```
    genAttrs = lib.genAttrs;

    # eachSystem :: (builder :: String -> AttrSet) -> AttrSet
    #
    # ```
    # > eachSystem (system: { a = 123; b = "cool ${system}"; })
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
    # ```
    eachSystem = builder: genAttrs systems builder;

    # The "host" nixpkgs for each system.
    #
    # ```
    # {
    #   "aarch64-darwin" = <nixpkgs>;
    #   "x86_64-linux" = <nixpkgs>;
    # }
    # ```
    systemPkgs = eachSystem (system: inputs.nixpkgs.legacyPackages.${system});

    # mkPkgsUnfree :: NixpkgsFlakeInput -> String -> NixpkgsPackageSet
    #
    # Builds a `pkgs` set that allows unfree packages, like the Android SDK.
    # Keep this as a separate package set for eval efficiency.
    mkPkgsUnfree = nixpkgsFlake: system:
      import nixpkgsFlake {
        system = system;
        config = {
          android_sdk.accept_license = true;
          allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [
              "android-sdk-tools"
              "android-sdk-cmdline-tools"
            ];
        };
      };

    # Host nixpkgs set that allows "unfree" packages, like the Android SDK.
    systemPkgsUnfree = eachSystem (system: mkPkgsUnfree inputs.nixpkgs system);

    # eachSystemPkgs :: (builder :: Nixpkgs -> AttrSet) -> AttrSet
    eachSystemPkgs = builder: eachSystem (system: builder systemPkgs.${system});

    # My custom packages for each system.
    systemPhlipPkgs = eachSystemPkgs (pkgs:
      import ./pkgs/default.nix {
        pkgs = pkgs;
      });
  in {
    packages = eachSystem (system: let
      # pkgs = systemPkgs.${system};
      hmPkgs = inputs.home-manager.packages.${system};
      phlipPkgs = systemPhlipPkgs.${system};
    in {
      # Re-export home-manager package so we can easily reference it on
      # first-time setup for a new machine.
      home-manager = hmPkgs.home-manager;

      dotenvy = phlipPkgs.dotenvy;
      firefox-profiler = phlipPkgs.firefox-profiler;
      mcp-server-filesystem = phlipPkgs.mcp-server-filesystem;
      samply = phlipPkgs.samply;
    });

    # home-manager configurations for different hosts

    homeConfigurations."phlipdesk" = inputs.home-manager.lib.homeManagerConfiguration rec {
      pkgs = systemPkgs."x86_64-linux";
      lib = pkgs.lib;
      modules = [./home/phlipdesk.nix];

      # Use `extraSpecialArgs` to pass through arguments from the flake.nix to
      # the home-manager modules.
      extraSpecialArgs = {
        inputs = inputs;
        phlipPkgs = systemPhlipPkgs.${pkgs.system};
        pkgsUnfree = systemPkgsUnfree.${pkgs.system};
      };

      check = true;
    };

    homeConfigurations."phliptop-nitro" = inputs.home-manager.lib.homeManagerConfiguration rec {
      pkgs = systemPkgs."x86_64-linux";
      lib = pkgs.lib;
      modules = [./home/phliptop-nitro.nix];

      # Use `extraSpecialArgs` to pass through arguments from the flake.nix to
      # the home-manager modules.
      extraSpecialArgs = {
        inputs = inputs;
        phlipPkgs = systemPhlipPkgs.${pkgs.system};
        pkgsUnfree = systemPkgsUnfree.${pkgs.system};
      };

      check = true;
    };

    homeConfigurations."phliptop-mbp" = inputs.home-manager.lib.homeManagerConfiguration rec {
      pkgs = systemPkgs."aarch64-darwin";
      lib = pkgs.lib;
      modules = [./home/phliptop-mbp.nix];

      # Use `extraSpecialArgs` to pass through arguments from the flake.nix to
      # the home-manager modules.
      extraSpecialArgs = {
        inputs = inputs;
        phlipPkgs = systemPhlipPkgs.${pkgs.system};
        pkgsUnfree = systemPkgsUnfree.${pkgs.system};
      };

      check = true;
    };

    # The *.nix file formatter.
    formatter = eachSystemPkgs (pkgs: pkgs.alejandra);

    devShells = eachSystemPkgs (pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          # nix language server
          pkgs.nil

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

    _dbg = {
      lib = lib;
      systemPkgs = systemPkgs;
      systemPkgsUnfree = systemPkgsUnfree;
      systemPhlipPkgs = systemPhlipPkgs;
    };
  };
}
