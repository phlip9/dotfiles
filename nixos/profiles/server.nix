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

  # Bootloader
  boot.loader = {
    # Servers don't need to save many boot generations.
    grub.configurationLimit = lib.mkDefault 4;
    systemd-boot.configurationLimit = lib.mkDefault 4;

    # Servers are headless, don't wait for someone to select a boot entry.
    timeout = 0;
  };

  # Ensure a clean & sparkling /tmp on fresh boots.
  boot.tmp.cleanOnBoot = lib.mkDefault true;

  # Systemd
  systemd = {
    # Servers run 24/7.
    sleep.extraConfig = ''
      AllowSuspend=no
      AllowHibernation=no
    '';

    # Enable hardware-integrated systemd watchdog.
    # See: <https://0pointer.de/blog/projects/watchdog.html>
    settings.Manager = {
      # systemd will send a signal to the hardware watchdog at half the interval
      # defined here, so every 7.5s. If the hardware watchdog does not get a
      # signal for 15s, it will forcefully reboot the system.
      RuntimeWatchdogSec = lib.mkDefault "15s";
      # Forcefully reboot if the final stage of the reboot hangs without
      # progress for more than 30s.
      # See: <https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdShutdownWatchdog>
      RebootWatchdogSec = lib.mkDefault "30s";
      # Forcefully reboot when a host hangs after kexec. This may be the case
      # when the firmware does not support kexec.
      KExecWatchdogSec = lib.mkDefault "1m";
    };
  };

  # Make sure the serial console is visible in qemu when testing the server
  # configuration with nixos-rebuild build-vm
  virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;

  # Firewall
  networking.firewall = {
    enable = true;

    # Allow PMTU / DHCP
    allowPing = true;

    # Keep dmesg/journalctl -k output readable by NOT logging
    # each refused connection on the open internet.
    logRefusedConnections = lib.mkDefault false;
  };

  # Don't use insecure Link-Local Multicast Name Resolution
  services.resolved.settings.Resolve.LLMNR = lib.mkDefault false;

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

  # Nix
  nix = {
    # Collect garbage weekly. deletes unused items in the `/nix/store`.
    gc = {
      automatic = true;
      dates = "weekly";
      # args passed to `nix-collect-garbage`
      #   --delete-old           : deletes all older profiles
      #   --delete-older-than Xd : deletes profiles older than X days
      options = "--delete-older-than 7d";
    };

    # Optimise the nix store periodically
    optimise = {
      # Nix will detect files in the store with identical contents and replace
      # them with hard links to a single copy. Can save some disk space.
      automatic = true;
      dates = "daily";
    };

    settings = {
      # We'll optimise on a schedule, see above.
      auto-optimise-store = false;

      # Avoid disk full issues
      max-free = lib.mkDefault (5 * 1024 * 1024 * 1024); # 5 GiB
      min-free = lib.mkDefault (512 * 1024 * 1024); # 0.5 GiB

      # Fallback quickly if substituters are not available.
      connect-timeout = lib.mkDefault 5;
      fallback = true;

      # Avoid copying unnecessary stuff over SSH
      builders-use-substitutes = true;

      # The default at 10 is rarely enough.
      log-lines = lib.mkDefault 25;

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

  # Reduce priority of nix-gc
  systemd.services.nix-gc.serviceConfig = {
    CPUSchedulingPolicy = "batch";
    IOSchedulingClass = "idle";
    IOSchedulingPriority = 7;
  };

  # Make builds to be more likely killed than important services.
  # 100 is the default for user slices and 500 is systemd-coredumpd@
  # We rather want a build to be killed than our precious user sessions as
  # builds can be easily restarted.
  systemd.services.nix-daemon.serviceConfig.OOMScoreAdjust = lib.mkDefault 250;

  # Locale
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # sudo-rs - memory-safe sudo
  security.sudo-rs = {
    enable = true;
    execWheelOnly = true;
  };

  # password-less sudo for wheel group
  security.sudo-rs.wheelNeedsPassword = false;

  environment = {
    # Basic packages
    systemPackages = with pkgs; [
      curl
      dnsutils
      gitMinimal
      htop
      jq
      rsync
    ];

    # Print the URL instead on servers
    variables.BROWSER = "echo";

    # Don't install the /lib/ld-linux.so.2 and /lib64/ld-linux-x86-64.so.2 stubs.
    stub-ld.enable = lib.mkDefault false;
  };

  # Enable docs
  documentation = {
    enable = true;
    doc.enable = true;
    info.enable = true;
    man.enable = true;
    nixos.enable = true;
  };

  # Servers don't need fonts
  fonts.fontconfig.enable = false;
}
