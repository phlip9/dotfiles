# NixOS VM tests
{
  pkgs,
  sources,
}:

let
  # Our extra NixOS modules that are always include
  extraModules = import ../mods { inherit sources; };

  # Create a new NixOS test with our defaults
  runNixOSTest =
    testModule:
    pkgs.testers.runNixOSTest {
      # test module (NOT a NixOS module)
      imports = [ testModule ];

      # NixOS machine config defaults
      defaults = {
        # Add our base modules/extra module args
        # NOTE: `runNixOSTest` already makes our pkgs set read-only.
        imports = [
          { _module.args.sources = sources; }
        ]
        ++ extraModules;

        # Enable sshd so sops uses the ssh host key to decrypt secrets.
        services.openssh = {
          enable = true;
          hostKeys = [
            {
              type = "ed25519";
              path = "/etc/ssh/ssh_host_ed25519_key";
            }
          ];
        };

        # Provide a deterministic host key for the test VM.
        system.activationScripts.test-ssh-host-key.text = ''
          install -Dm400 ${./fixtures/id_ed25519} /etc/ssh/ssh_host_ed25519_key
        '';

        # SOPS configuration for test
        sops = {
          defaultSopsFile = ./fixtures/secrets.yaml;
        };
      };
    };
in

{
  github-webhook = runNixOSTest ./github-webhook.nix;
}
