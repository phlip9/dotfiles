{
  pkgs,
  pkgsUnstable,
  nixpkgs,
}:
rec {
  # pkgsCross = import nixpkgs {
  #   localSystem = "x86_64-linux";
  #   crossSystem = {
  #     # config = "x86_64-unknown-linux-gnu";
  #     # rustc.config = "x86_64-fortanix-unknown-sgx";
  #     # isStatic = true;
  #   };
  #
  #   crossSystem = {
  #     config = "x86_64-unknown-linux-gnu";
  #     rustc.config = "x86_64-fortanix-unknown-sgx";
  #     # useLLVM = true;
  #   };
  # };

  # "fenix": {
  #   "inputs": {
  #     "nixpkgs": [
  #       "nixpkgs"
  #     ],
  #     "rust-analyzer-src": []
  #   },
  #   "locked": {
  #     "lastModified": 1760596988,
  #     "narHash": "sha256-+h9FVfiNnsWKpk2HiaecPocq4gWD9GNn5/eVS3I9Z+8=",
  #     "owner": "nix-community",
  #     "repo": "fenix",
  #     "rev": "8e99c7d8e07635dea2e1001485f9de41bb1587f2",
  #     "type": "github"
  #   },
  #   "original": {
  #     "owner": "nix-community",
  #     "repo": "fenix",
  #     "type": "github"
  #   }
  # },
  fenix = fetchLockedFlake {
    lastModified = 1760596988;
    narHash = "sha256-+h9FVfiNnsWKpk2HiaecPocq4gWD9GNn5/eVS3I9Z+8=";
    owner = "nix-community";
    repo = "fenix";
    rev = "8e99c7d8e07635dea2e1001485f9de41bb1587f2";
    type = "github";
  };

  fenixPkgs = import fenix {
    system = "x86_64-linux";
    # inherit pkgs;
    pkgs = pkgs;
  };

  fenix-rustc-unwrapped = fenixPkgs.stable.withComponents [
    "rustc"
    "rust-std"
  ];

  fenix-rustc = pkgsUnstable.wrapRustc (
    fenix-rustc-unwrapped
    // rec {
      name = "${pname}-${version}";
      pname = "rustc-unwrapped";
      version = "1.90.0";
      meta = fenix-rustc-unwrapped.meta // {
        description = "rustc";
      };
    }
  );

  # fenixToolchain = fenixPkgs.stable.withComponents [
  #   "rustc"
  #   "cargo"
  # ];

  # # build : normal
  # # host : normal
  # # target : SGX
  # pkgsBuildTarget = pkgsCross.pkgsBuildTarget;

  std-orig = pkgs.callPackage ./rust-std.nix { };

  # std = pkgs.callPackage ./rust-std2.nix {
  #   rustc = fenix-rustc;
  #   cargo = fenixPkgs.stable.cargo;
  # };

  std3 = pkgs.callPackage ./rust-std3.nix {
    rustc = fenix-rustc;
    cargo = fenixPkgs.stable.cargo;
  };

  std = pkgs.callPackage ./rust-std4.nix {
    rustc = fenix-rustc;
    cargo = fenixPkgs.stable.cargo;
  };

  vendor = pkgs.callPackage ./rust-std-vendor.nix {
    rustc = fenix-rustc;
    cargo = fenixPkgs.stable.cargo;
  };

  # std = pkgsUnstable.callPackage ./rust-std2.nix { };

  fetchLockedFlake =
    builtins.fetchTree or (
      locked:
      if locked.type != "github" then
        throw "error: unsupported flake input type: ${locked.type}"
      else
        {
          outPath = builtins.fetchTarball {
            url = "https://api.github.com/repos/${locked.owner}/${locked.repo}/tarball/${locked.rev}";
            sha256 = locked.narHash;
          };
          rev = locked.rev;
          shortRev = builtins.substring 0 7 locked.rev;
          lastModified = locked.lastModified;
          lastModifiedDate = "19700101000000";
          narHash = locked.narHash;
        }
    );
}
