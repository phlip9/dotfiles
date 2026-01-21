# Headless server profile
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    # Use minimal+headless (no GUI/window manager) for server images
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/headless.nix")
  ];

  # Firewall
  networking.firewall.enable = true;

  # OpenSSH
  # SSH server on non-standard port 22022 w/ some hardened settings.
  # Use non-standard port to silence ssh bots...
  services.openssh = {
    enable = true;
    ports = [ 22022 ];
    openFirewall = true;

    # Only generate an ed25519 key and not an RSA key.
    # This is just the default value w/o the type=rsa entry.
    hostKeys = [
      {
        type = "ed25519";
        path = "/etc/ssh/ssh_host_ed25519_key";
      }
    ];

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = lib.mkForce "no";
      KbdInteractiveAuthentication = false;
      X11Forwarding = false;

      # Only allow a single set of crypto primitives.
      KexAlgorithms = [
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
      ];
      Macs = [ "hmac-sha2-256-etm@openssh.com" ];
      Ciphers = [ "aes128-gcm@openssh.com" ];
    };
  };

  # Nix settings
  nix = {
    # Collect garbage weekly. deletes unused items in the `/nix/store`.
    gc = {
      automatic = true;
      dates = "monthly";
      # args passed to `nix-collect-garbage`
      #   --delete-old           : deletes all older profiles
      #   --delete-older-than Xd : deletes profiles older than X days
      options = "--delete-older-than 7d";
    };

    settings = {
      # Nix will detect files in the store with identical contents and replace
      # them with hard links to a single copy. Can save some disk space.
      auto-optimise-store = true;

      # Allow all sudoers to manage NixOS system.
      trusted-users = [
        "root"
        "@wheel"
      ];

      # Enable `nix` command and flakes support
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };

  # Locale
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # sudo-rs - memory-safe sudo
  security.sudo-rs = {
    enable = true;
    execWheelOnly = true;
  };

  # Basic packages
  environment.systemPackages = with pkgs; [
    bind.dnsutils
    git
    htop
    rsync
  ];
}
