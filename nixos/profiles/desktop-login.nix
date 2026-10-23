# desktop login greeter config
#
# goal: enter LUKS FDE password -> autologin to desktop
#
# see: <nixos/tests/desktop-login.nix>
{
  config,
  lib,
  phlipPkgsNixos,
  pkgs,
  ...
}:
{
  #
  # Login greeter
  #

  # minimal greetd auto-login direct to niri-session
  # - docs: <https://man.sr.ht/~kennylevinsen/greetd>
  services.greetd = {
    enable = true;
    package = phlipPkgsNixos.greetd;
    useTextGreeter = true;
    settings =
      let
        autoLogin = config.services.displayManager.autoLogin;
        niri-session = lib.getExe' pkgs.niri "niri-session";
      in
      {
        general.service = "greetd-login";
        # initial autologin to niri desktop
        initial_session = lib.mkIf autoLogin.enable {
          command = niri-session;
          user = autoLogin.user;
          service = "greetd-autologin";
        };
        # after logout/crash, require PAM auth instead of reopening a desktop
        default_session = {
          command = lib.concatStringsSep " " [
            (lib.getExe' config.services.greetd.package "agreety")
            "--cmd"
            niri-session
          ];
          user = "greeter";
          service = "greetd-login";
        };
      };
  };

  systemd.services.greetd.serviceConfig = {
    # `agreety` exits after five bad attempts. `greetd` can then exit with 0
    Restart = lib.mkForce "always";
  };

  # `greetd` shares kernel keyring w/ root. Isolate every session before a
  # greeter, user daemon, or user-controlled shell can inherit the LUKS cache.
  # Keep normal auth and account/password/session policy in NixOS greetd.
  security.pam.services.greetd-login.text =
    let
      pamLib = lib.getLib config.security.pam.package;
    in
    ''
      auth substack greetd
      account include greetd
      password substack greetd
      session requisite ${pamLib}/lib/security/pam_keyinit.so force
      session include greetd
    '';

  # Autologin leaves GNOME Keyring locked, so Noctalia's encrypted clipboard
  # history triggers a password prompt at startup. Patched greetd runs this
  # auth stack to unlock the keyring with systemd's cached LUKS passphrase.
  # LUKS and the Login keyring must use the same passphrase. If the cache is
  # unavailable, autologin still works and GNOME Keyring can prompt later.
  # Inherit the same session isolation and policy as manual logins.
  security.pam.services.greetd-autologin =
    lib.mkIf config.services.displayManager.autoLogin.enable
      {
        text =
          let
            autoLogin = config.services.displayManager.autoLogin;
            pamLib = lib.getLib config.security.pam.package;
            systemdLib = lib.getLib config.systemd.package;
            gcrLib = lib.getLib pkgs.gnome-keyring;
          in
          ''
            auth requisite ${pamLib}/lib/security/pam_succeed_if.so \
              user = ${autoLogin.user}
            auth optional ${systemdLib}/lib/security/pam_systemd_loadkey.so
            auth optional ${gcrLib}/lib/security/pam_gnome_keyring.so
            auth required ${pamLib}/lib/security/pam_permit.so
            account include greetd-login
            password substack greetd-login
            session include greetd-login
          '';
      };
}
