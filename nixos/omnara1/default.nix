# omnara1 - Hetzner bare metal dev server
#
# Hardware:
# - 2x 894 GiB NVMe SSDs in RAID 0
# - IPv4: 95.217.195.225
# - IPv6: 2a01:4f9:4a:52de::2
{
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware.nix
    ./disko-config.nix
    ../profiles/server.nix
  ];

  system.stateVersion = "26.05";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Bootloader
  boot.loader = {
    grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };

  # Use latest kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Silence mdadm warning about missing MAILADDR or PROGRAM
  boot.swraid.mdadmConf = "PROGRAM ${pkgs.coreutils}/bin/true";

  # Hostname
  networking.hostName = "omnara1";
  networking.domain = "phlip9.com";

  # Use systemd networkd
  systemd.network.enable = true;
  networking.useNetworkd = true;

  # Static network configuration (Hetzner)
  networking.wireless.enable = false;
  networking.useDHCP = false;
  networking.interfaces.eno1 = {
    ipv4.addresses = [
      {
        address = "95.217.195.225";
        prefixLength = 26;
      }
    ];
    ipv6.addresses = [
      {
        address = "2a01:4f9:4a:52de::2";
        prefixLength = 64;
      }
    ];
  };
  networking.defaultGateway = {
    address = "95.217.195.193";
    interface = "eno1";
  };
  networking.defaultGateway6 = {
    address = "fe80::1";
    interface = "eno1";
  };
  networking.nameservers = [
    "185.12.64.1"
    "185.12.64.2"
    "2a01:4ff:ff00::add:1"
    "2a01:4ff:ff00::add:2"
  ];
  services.timesyncd.servers = [
    "ntp1.hetzner.de"
    "ntp2.hetzner.com"
    "ntp3.hetzner.net"
  ];

  # Expose HTTP/HTTPS for webhook ingress + ACME HTTP-01.
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # ACME for omnara1.phlip9.com certificates.
  security.acme = {
    acceptTerms = true;
    defaults.email = "philiphayes9@gmail.com";
  };

  # TLS terminates here; proxy to local dotfiles-webhook service.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedBrotliSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedTlsSettings = true;

    # Log to journald
    logError = "syslog:server=unix:/dev/log,nohostname,tag=nginx_error warn";
    commonHttpConfig = ''
      log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    '';
    appendHttpConfig = ''
      access_log syslog:server=unix:/dev/log,nohostname,tag=nginx,severity=info main;
    '';

    virtualHosts."omnara1.phlip9.com" = {
      forceSSL = true;
      enableACME = true;

      extraConfig = ''
        client_max_body_size 256k;
      '';

      locations."/webhooks/github" = {
        proxyPass = "http://[::1]:8673/webhooks/github";
        extraConfig = ''
          proxy_read_timeout 5s;
          proxy_connect_timeout 5s;
        '';
      };

      locations."/healthz" = {
        proxyPass = "http://[::1]:8673/healthz";
        extraConfig = ''
          proxy_read_timeout 5s;
          proxy_connect_timeout 5s;
        '';
      };
    };
  };

  # users and groups are static and must be configured via nix
  users.mutableUsers = false;

  # user
  users.users.phlip9 = {
    isNormalUser = true;
    description = "Philip Kannegaard Hayes";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = import ../../nix/ssh-pubkeys.nix;

    # Enable "linger" so that systemd will start the user service and all
    # `default.target`-triggered user services automatically on boot.
    linger = true;
  };

  # Run non-NixOS binaries
  programs.nix-ld = {
    enable = true;
    libraries = [
    ];
  };

  # repo updates -> receive webhook -> fetch+reset
  services.github-webhook = {
    enable = true;
    user = "phlip9";
    repos =
      let
        cmdFetchReset = builtins.toString (
          pkgs.writeShellScript "phlip9-dotfiles-fetch-reset.sh" ''
            set -euxo pipefail
            git fetch upstream
            git reset --hard upstream/master
          ''
        );
      in
      {
        "phlip9/dotfiles" = {
          secretName = "dotfiles-github-webhook-secret";
          branches = [ "master" ];
          command = [ cmdFetchReset ];
          workingDir = "/home/phlip9/dev/dotfiles";
          runOnStartup = true;
        };

        "lexe-app/lexe" = {
          secretName = "lexe-github-webhook-secret";
          branches = [ "master" ];
          command = [ cmdFetchReset ];
          workingDir = "/home/phlip9/dev/lexe";
          runOnStartup = true;
        };
      };
  };
  sops.secrets = {
    dotfiles-github-webhook-secret = { };
    lexe-github-webhook-secret = { };
  };

  # =========================================================================
  # Buildbot CI
  # =========================================================================
  # see: doc/buildbot-nix-ci.md
  # see: nixos/mods/buildbot-ci.nix
  services.phlip9-buildbot-ci = {
    enable = true;
    domain = "ci.phlip9.com";
    cacheDomain = "cache.phlip9.com";

    github = {
      appId = 2746100;
      # OAuth App Client ID for oauth2-proxy (fullyPrivate mode)
      oauthClientId = "Ov23lipvJOGiZTG0aqv9";
    };

    cloudflare = {
      accountId = "30faeb30dcb2a77a72fdc0948c99de62";
      bucket = "phlip9-nix-cache";
    };

    cache.publicKey = "cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4=";
  };
  # PostgreSQL for Buildbot CI
  services.postgresql = {
    # Pin the major version to avoid accidentally breaking the DB on nixos
    # version update.
    package = pkgs.postgresql_18;

    # Don't need to expose the postgres to non-local connections
    enableTCPIP = false;
  };
}
