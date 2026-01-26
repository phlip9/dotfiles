# serokell/deploy-rs configs for phlip9's deployable machines.
{
  pkgs,
  nodes ? [ ],
}:

let
  # This is vendored from deploy-rs flake.nix
  mkDeployLib =
    pkgs:
    let
      inherit (pkgs)
        buildEnv
        deploy-rs
        lib
        runtimeShell
        writeScript
        writeTextFile
        ;
    in
    {
      activate = rec {
        custom = {
          __functor =
            customSelf: base: activate:
            buildEnv {
              name = ("activatable-" + base.name);
              paths = [
                #
                base

                #
                (writeTextFile {
                  name = base.name + "-activate-path";
                  text = ''
                    #!${runtimeShell}
                    set -euo pipefail

                    if [[ "''${DRY_ACTIVATE:-}" == "1" ]]
                    then
                        ${customSelf.dryActivate or "echo ${writeScript "activate" activate}"}
                    elif [[ "''${BOOT:-}" == "1" ]]
                    then
                        ${customSelf.boot or "echo ${writeScript "activate" activate}"}
                    else
                        ${activate}
                    fi
                  '';
                  executable = true;
                  destination = "/deploy-rs-activate";
                })

                #
                (writeTextFile {
                  name = base.name + "-activate-rs";
                  text = ''
                    #!${runtimeShell}
                    exec ${lib.getExe' deploy-rs "activate"} "$@"
                  '';
                  executable = true;
                  destination = "/activate-rs";
                })
              ];
            };
        };

        # deploy a NixOS configuration
        nixos =
          base:
          (
            custom
            // {
              dryActivate = "$PROFILE/bin/switch-to-configuration dry-activate";
              boot = "$PROFILE/bin/switch-to-configuration boot";
            }
          )
            base.config.system.build.toplevel
            # TODO(phlip9): /run/current-system/bin/switch-to-configuration ?
            ''
              # work around https://github.com/NixOS/nixpkgs/issues/73404
              cd /tmp

              $PROFILE/bin/switch-to-configuration switch

              # https://github.com/serokell/deploy-rs/issues/31
              ${
                with base.config.boot.loader;
                lib.optionalString systemd-boot.enable "sed -i '/^default /d' ${efi.efiSysMountPoint}/loader/loader.conf"
              }
            '';

        # deploy a home-manager configuration
        home-manager = base: custom base.activationPackage "$PROFILE/activate";

        # Activation script for 'darwinSystem' from nix-darwin.
        # 'HOME=/var/root' is needed because 'sudo' on darwin doesn't change 'HOME' directory,
        # while 'darwin-rebuild' (which is invoked under the hood) performs some nix-channel
        # checks that rely on 'HOME'. As a result, if 'sshUser' is different from root,
        # deployment may fail without explicit 'HOME' redefinition.
        darwin =
          base:
          custom base.config.system.build.toplevel "HOME=/var/root $PROFILE/activate";

        noop = base: custom base ":";
      };
    };

  # Build a `deploy-rs` config for a machine configuration in
  # `../nixosConfigs/default.nix`.
  mkNixosDeploy = (
    nixosConfig:
    let
      cfg = nixosConfig.config;
      deployLib = mkDeployLib nixosConfig.pkgs;
    in
    {
      hostname = cfg.networking.fqdn;
      profiles.system.path = deployLib.activate.nixos nixosConfig;
    }
  );
in
{
  # All deployable nodes
  nodes = builtins.mapAttrs (name: nixosConfig: mkNixosDeploy nixosConfig) nodes;

  # Set deploy-rs default settings
  # See: <https://github.com/serokell/deploy-rs#generic-options>

  # ssh with non-standard port
  sshOpts = [
    "-p"
    "22022"
  ];
  # ssh to the machine as this user.
  sshUser = "phlip9";
  # Once on the machine, deploy the profile to this user.
  user = "root";

  # If the activation fails, reactivate the previous version.
  autoRollback = true;

  # When enabled, the deploy will automatically rollback if we can't
  # reconnect after. This prevents the machine from becoming unreachable.
  magicRollback = true;

  # Build locally
  remoteBuild = false;
}
