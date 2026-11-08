# NixOS VM + container tests
{
  # NixOS machine configs, for checks of what they deploy
  nixosConfigs,
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

        # Test networks are static. In VMs, dhcpcd only delays
        # `network-online.target` by ~6s waiting on a lease for qemu's
        # user-mode NIC. Containers already default to this.
        networking.useDHCP = pkgs.lib.mkDefault false;

        # Provide a deterministic host key for the guest. `environment.etc`
        # is set up before sops `setupSecrets` runs, so sops can use this key
        # on first boot.
        environment.etc."ssh/ssh_host_ed25519_key" = {
          source = ./fixtures/id_ed25519;
          mode = "0400";
        };

        # Set test secret:
        # `just sops-test-fixtures-set secret-name < <(echo "secret-value")`
        sops = {
          defaultSopsFile = ./fixtures/secrets.yaml;
        };
      };
    };
in

{
  desktop-login = runNixOSTest ./desktop-login.nix;
  github-agent-authd = runNixOSTest ./github-agent-authd.nix;
  github-webhook = runNixOSTest ./github-webhook.nix;
  nixbot = runNixOSTest ./nixbot.nix;
  o11y = runNixOSTest ./o11y.nix;
  o11y-alerting = runNixOSTest ./o11y-alerting.nix;
  # Offline check of sauna's alert rules + routing, not a NixOS test
  o11y-alerting-unit = import ./o11y-alerting-unit.nix {
    inherit nixosConfigs pkgs;
  };
  o11y-profiling = runNixOSTest ./o11y-profiling.nix;
  paseo = runNixOSTest ./paseo.nix;
  rbitcoin = runNixOSTest ./rbitcoin.nix;
}
