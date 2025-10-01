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
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
    # nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # A nixpkgs with an older version of `age-plugin-yubikey` that still uses
    # Client protocol 4:4 for communicating with `pcscd`. The latest release
    # upgraded to Client protocol 4:5, but `pcscd` packaged on Ubuntu only
    # supports Server protocol 4:4, causing `age-plugin-yubikey` to fail.
    # TODO(phlip9): remove once Ubuntu LTS packages `pcscd` with server protocol 4:5.
    nixpkgs-yubikey.url = "github:nixos/nixpkgs/807e9154dcb16384b1b765ebe9cd2bba2ac287fd";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
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
    # # nixpkgs-unstable for each system.
    # systemPkgsUnstable = eachSystem (system: inputs.nixpkgs-unstable.legacyPackages.${system});

    # mkPkgsUnfree :: NixpkgsFlakeInput -> String -> NixpkgsPackageSet
    #
    # Builds a `pkgs` set that allows unfree packages, like the Android SDK.
    # Keep this as a separate package set for eval efficiency.
    mkPkgsUnfree = nixpkgsFlake: system:
      import nixpkgsFlake {
        system = system;
        config = {
          android_sdk.accept_license = true;
          allowUnfreePredicate = let
            allowed = {
              android-sdk-build-tools = null;
              android-sdk-cmdline-tools = null;
              android-sdk-platform-tools = null;
              android-sdk-platforms = null;
              android-sdk-tools = null;
              android-sdk-ndk = null;
            };
          in
            pkg: allowed ? ${lib.getName pkg};
        };
      };

    # Host nixpkgs set that allows "unfree" packages, like the Android SDK.
    systemPkgsUnfree = eachSystem (system: mkPkgsUnfree inputs.nixpkgs system);

    # Host nixpkgs set with old age-plugin-yubikey and pcsclite packages that
    # support running against Ubuntu 24.04 LTS pcscd.
    systemPkgsYubikey = eachSystem (system: inputs.nixpkgs-yubikey.legacyPackages.${system});

    # eachSystemPkgs :: (builder :: Nixpkgs -> AttrSet) -> AttrSet
    eachSystemPkgs = builder: eachSystem (system: builder systemPkgs.${system});

    # My custom packages for each system.
    systemPhlipPkgs = eachSystem (system:
      import ./pkgs/default.nix {
        pkgs = systemPkgs.${system};
        # pkgsUnstable = systemPkgsUnstable.${system};
      });
  in {
    packages = eachSystem (system: let
      hmPkgs = inputs.home-manager.packages.${system};
      phlipPkgs = systemPhlipPkgs.${system};
    in {
      # Re-export home-manager package so we can easily reference it on
      # first-time setup for a new machine.
      home-manager = hmPkgs.home-manager;

      inherit
        (phlipPkgs)
        aider-chat
        cargo-release
        claude-code
        codex
        dist
        firefox-profiler
        git-restore-mtime
        goose-cli
        graviola-tools
        lossless-cut
        imgen
        lego
        mcp-server-filesystem
        momw-tools-pack
        openmw
        samply
        ;
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
        pkgsYubikey = systemPkgs.${pkgs.system};
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
        pkgsYubikey = systemPkgsYubikey.${pkgs.system};
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
        pkgsYubikey = systemPkgs.${pkgs.system};
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
      nixpkgs = inputs.nixpkgs;
      systemPkgs = systemPkgs;
      systemPkgsUnfree = systemPkgsUnfree;
      systemPkgsYubikey = systemPkgsYubikey;
      systemPhlipPkgs = systemPhlipPkgs;
    };
  };
}
