# Test initrd LUKS unlock -> kernel -> greetd -> PAM -> GNOME Keyring.
#
# Only the niri-session command is replaced. Use distinct Unix and LUKS
# passwords so successful keyring unlock cannot come from normal password auth.
#
# Run: nix build -f . nixosTests.desktop-login
let
  luksPassword = "test-luks-password";
  unixPassword = "test-unix-password";
in
{
  name = "desktop-login";
  globalTimeout = 300;

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      luksUUID = "55555555-5555-5555-5555-555555555555";
      probe =
        let
          python = pkgs.python3.withPackages (deps: [ deps.dbus-python ]);
        in
        pkgs.writeScript "desktop-login-probe" ''
          #!${python}/bin/python3
          ${builtins.readFile ./desktop-login/probe.py}
        '';
    in
    {
      imports = [ ../profiles/desktop-login.nix ];

      virtualisation.qemu.drives =
        let
          # A regular file needs no loop device or root to format.
          # No guest key file: the driver types the passphrase.
          luksImage =
            pkgs.runCommand "desktop-login-luks.img"
              {
                nativeBuildInputs = [ pkgs.cryptsetup ];
              }
              ''
                truncate -s 32M "$out"
                printf %s '${luksPassword}' | cryptsetup luksFormat \
                  --batch-mode --type luks2 --uuid ${luksUUID} --pbkdf pbkdf2 \
                  --pbkdf-force-iterations 1000 "$out" -
              '';
        in
        [
          {
            name = "luks";
            file = "${luksImage}";
            driveExtraOpts = {
              format = "raw";
              readonly = "on";
            };
          }
        ];

      # Match phlipdesk's kernel and initrd implementation.
      boot.kernelPackages = pkgs.linuxPackages_latest;
      boot.initrd.systemd.enable = true;
      # qemu-vm clears LUKS devices at priority 10. Keep a real initrd unlock,
      # even though the test framework supplies the VM's unencrypted root.
      boot.initrd.luks.devices = lib.mkOverride 5 {
        crypttest.device = "/dev/disk/by-uuid/${luksUUID}";
      };

      services.gnome.gnome-keyring.enable = true;
      services.displayManager.autoLogin = {
        enable = true;
        user = "alice";
      };
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        password = unixPassword;
      };

      environment.systemPackages = [
        pkgs.keyutils
        pkgs.pamtester
        pkgs.procps
      ];

      # Probe the inherited keyring from .profile, the desktop command, and
      # the greeter before bundled agreety starts.
      services.greetd.settings =
        let
          session = pkgs.writeShellScript "test-desktop-session" ''
            exec ${probe} session
          '';
        in
        {
          initial_session.command = lib.mkForce session;
          default_session.command = lib.mkForce (
            lib.concatStringsSep " " [
              probe
              "greeter"
              (lib.getExe' config.services.greetd.package "agreety")
              "--cmd"
              session
            ]
          );
        };
      systemd.tmpfiles.rules = [
        "d /run/login-test 0755 root root -"
        "d /run/login-test/greeter 0755 greeter greeter -"
      ];

      # Seed an encrypted Login keyring on a private bus, then let systemd
      # kill that bus and daemon before greetd starts. PAM must unlock it.
      systemd.services.seed-login-keyring =
        let
          seed = pkgs.writeShellScript "seed-login-keyring" ''
            set -eu
            export HOME=/home/alice
            eval "$(printf %s '${luksPassword}' | \
              ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --unlock)"
            export GNOME_KEYRING_CONTROL
            ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon \
              --start --components=secrets
            printf %s fixture-secret | ${pkgs.libsecret}/bin/secret-tool store \
              --label='Desktop login test' test desktop-login
            test -s "$HOME/.local/share/keyrings/login.keyring"
          '';
        in
        {
          requiredBy = [ "greetd.service" ];
          before = [ "greetd.service" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          unitConfig.ConditionPathExists = "!/home/alice/.profile";
          serviceConfig.Type = "oneshot";
          script = ''
            set -eu
            ${pkgs.util-linux}/bin/setpriv --reuid=alice --regid=users \
              --init-groups ${pkgs.dbus}/bin/dbus-run-session \
              --dbus-daemon=${pkgs.dbus}/bin/dbus-daemon -- ${seed}
            install -o alice -g users -m 0644 /dev/stdin \
              /home/alice/.profile <<EOF
            ${probe} profile
            EOF
          '';
        };

      # Fail if the initrd did not leave the *real* LUKS password in root's
      # kernel keyring. Publish only its serial so unprivileged probes can
      # attempt direct reads, avoiding a vacuous "search found nothing".
      systemd.services.check-luks-cache = {
        requiredBy = [ "greetd.service" ];
        before = [ "greetd.service" ];
        after = [ "seed-login-keyring.service" ];
        path = [ pkgs.keyutils ];
        serviceConfig = {
          Type = "oneshot";
          KeyringMode = "shared";
        };
        script = ''
          set -eu
          key=$(keyctl search @u user cryptsetup)
          test "$(keyctl pipe "$key")" = '${luksPassword}'
          echo "$key" > /run/login-test/cache-id
        '';
      };
    };

  testScript = ''
    import json

    def read_probe(path):
        """Read a probe written by the actual greetd child, not runuser."""
        try:
            machine.wait_for_file(path, timeout=30)
        except Exception:
            machine.log(machine.succeed("journalctl -b -u greetd --no-pager"))
            machine.log(machine.get_tty_text("1"))
            raise
        return json.loads(machine.succeed(f"cat {path}"))

    def assert_isolated(result, uid):
        """Both discovery and direct reads must fail for the cached key."""
        assert result["uid"] == uid, result
        assert result["search_denied"], result
        assert result["read_denied"], result
        assert result["password_absent_from_env"], result

    machine.start()
    machine.wait_for_console_text("Please enter passphrase for disk crypttest")
    machine.send_console("${luksPassword}\n")
    machine.wait_for_unit("greetd.service")
    machine.succeed("test -b /dev/mapper/crypttest")

    with subtest("LUKS passphrase unlocks an existing encrypted Login keyring"):
        initial = read_probe("/home/alice/session.json")
        assert_isolated(initial, 1000)
        assert initial["unlocked"], initial
        assert initial["secret"] == "fixture-secret", initial
        assert_isolated(read_probe("/home/alice/profile.json"), 1000)
        machine.succeed("test -f /run/greetd.run")
        machine.fail("pamtester greetd-autologin root authenticate")

    with subtest("logout falls back to an isolated, unprivileged agreety"):
        machine.succeed(f"kill {initial['pid']}")
        machine.wait_until_succeeds("pgrep -u greeter -x agreety")
        greeter = read_probe("/run/login-test/greeter/probe.json")
        uid = int(machine.succeed("id -u greeter").strip())
        assert_isolated(greeter, uid)
        machine.succeed("rm /home/alice/session.json")

    with subtest("manual login requires the Unix password, not the LUKS cache"):
        daemon_pid = machine.succeed("systemctl show greetd -p MainPID --value")
        machine.wait_until_tty_matches("1", r"login: \s*$", timeout=30)
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("1", r"Password: \s*$", timeout=30)
        machine.send_chars("${luksPassword}\n")
        machine.wait_until_tty_matches("1", "Login incorrect", timeout=30)
        machine.fail("test -e /home/alice/session.json")
        machine.wait_until_tty_matches("1", r"login: \s*$", timeout=30)
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("1", r"Password: \s*$", timeout=30)
        machine.send_chars("${unixPassword}\n")
        assert_isolated(read_probe("/home/alice/session.json"), 1000)
        assert daemon_pid == machine.succeed(
            "systemctl show greetd -p MainPID --value"
        ), "greetd crashed during password auth"

    with subtest("greetd restart does not repeat initial autologin"):
        machine.succeed("systemctl restart greetd")
        machine.wait_until_succeeds("pgrep -u greeter -x agreety")
        machine.fail("pgrep -u alice -f '^.*desktop-login-probe session$'")
  '';
}
