# sauna - Hetzner bare metal dev server
#
# Hardware:
# - 2x 894 GiB NVMe SSDs in RAID 0
# - IPv4: 95.217.195.225
# - IPv6: 2a01:4f9:4a:52de::2
{
  config,
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
  networking.hostName = "sauna";
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

  # ACME for sauna.phlip9.com certificates.
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
      log_format main '$status $request - '
                      'ip=$remote_addr from="$http_user_agent" '
                      'rx=$request_length tx=$body_bytes_sent '
                      't=$request_time ms '
                      'ref="$http_referer"';
    '';
    appendHttpConfig = ''
      access_log syslog:server=unix:/dev/log,nohostname,tag=nginx,severity=info main;
    '';

    virtualHosts."sauna.phlip9.com" = {
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
    extraGroups = [
      "wheel"
      "github-agent" # github-agent-authd group
    ];
    openssh.authorizedKeys.keys = import ../../nix/ssh-pubkeys.nix;

    # Pin the auto-allocated uid so services can locate the user manager and
    # runtime dir at eval time (ex: services.paseo).
    uid = 1000;

    # Enable "linger" so that systemd will start the user service and all
    # `default.target`-triggered user services automatically on boot.
    linger = true;
  };

  # =========================================================================
  # resource control
  # =========================================================================
  # setup different cgroup tiers so important services stay responsive even
  # under heavy CPU/memory pressure:
  # - system.slice: infra (sshd, nginx, grafana, victoriametrics, ...)
  # - workload.slice: killable, restartable agent + CI work
  # - user.slice: my ssh/tmux sessions + user services

  # ### system.slice
  # avoid reclaiming pages from important services when under mem pressure
  systemd.slices.system.sliceConfig.MemoryLow = "4G";

  # ### workload.slice
  # reserve 15% mem for system services. cap swap for faster OOMs (instead of
  # thrashing to swap). no IOWeight since NVMe `none` scheduler ignores it.
  systemd.slices.workload = {
    description = "nix, paseo, and CI workloads";
    sliceConfig = {
      MemoryMax = "85%";
      MemorySwapMax = "8G";
      CPUWeight = 25;
    };
  };
  systemd.services.niks3.serviceConfig.Slice = "workload.slice";
  systemd.services.nix-daemon.serviceConfig.Slice = "workload.slice";
  systemd.services.nix-gc.serviceConfig.Slice = "workload.slice";
  systemd.services.nix-optimise.serviceConfig.Slice = "workload.slice";
  systemd.services.nixbot.serviceConfig.Slice = "workload.slice";
  systemd.services.paseo.serviceConfig.Slice = "workload.slice";

  # ### user.slice
  systemd.slices.user.sliceConfig = {
    MemoryMax = "75%";
    MemorySwapMax = "8G";
  };

  # systemd-oomd: userspace backstop OOM killer. Doesn't monitor any cgroups by
  # default. oomd SIGKILLs a whole leaf cgroup (e.g. paseo.service). memory
  # pressure in system.slice is usually caused by other tiers, so monitoring it
  # would likely kill more critical system services.
  #
  # - pressure: workload.slice or a user slice has memory PSI full > 80% for
  #   30s -> kill its child w/ the highest reclaim rate. Catches page cache
  #   refault thrash under a MemoryMax, where the kernel never OOMs.
  # - swap: free mem < 10% and free swap < 10% -> kill the cgroup w/ the most
  #   swap, anywhere.
  systemd.oomd.enableUserSlices = true;
  systemd.slices.workload.sliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "80%";
  };
  systemd.slices."-".sliceConfig.ManagedOOMSwap = "kill";

  # Run non-NixOS binaries
  programs.nix-ld = {
    enable = true;
    libraries = [
    ];
  };

  # repo updates -> receive webhook -> fetch+reset
  #
  # ## New repo setup runbook
  #
  # - Add new sops webhook secret: $(openssl rand -base64 32 | tr -d '+/=' | head -c 32)
  # - Add new entry below
  # - Redeploy
  # - Add webhook: <https://github.com/XXX/YYY/settings/hooks/new>
  #   - Payload URL: `https://sauna.phlip9.com/webhooks/github`
  #   - Content type: `application/json`
  #   - Secret: (from above)
  #   - SSL verification: Yes
  #   - Events: "Just the `push` event."
  #   - Active: Yes
  services.github-webhook = {
    enable = true;
    user = "phlip9";
    repos =
      let
        cmdFetchResetMaster = builtins.toString (
          pkgs.writeShellScript "fetch-reset-origin-master.sh" ''
            set -euxo pipefail
            git fetch origin
            git reset --hard origin/master
          ''
        );
        cmdFetchResetMain = builtins.toString (
          pkgs.writeShellScript "fetch-reset-origin-main.sh" ''
            set -euxo pipefail
            git fetch origin
            git reset --hard origin/main
          ''
        );
      in
      {
        "phlip9/dotfiles" = {
          secretName = "github-webhook-secret-phlip9-dotfiles";
          branches = [ "master" ];
          command = [ cmdFetchResetMaster ];
          workingDir = "/home/phlip9/dev/dotfiles";
          runOnStartup = true;
        };

        "phlip9/rbitcoin" = {
          secretName = "github-webhook-secret-phlip9-rbitcoin";
          branches = [ "master" ];
          command = [ cmdFetchResetMaster ];
          workingDir = "/home/phlip9/dev/rbitcoin";
          runOnStartup = true;
        };

        "phlip9/vss-server" = {
          secretName = "github-webhook-secret-phlip9-vss-server";
          branches = [ "main" ];
          command = [ cmdFetchResetMain ];
          workingDir = "/home/phlip9/dev/ldk-vss-server";
          runOnStartup = true;
        };

        "lexe-app/lexe" = {
          secretName = "github-webhook-secret-lexeapp-lexe";
          branches = [ "master" ];
          command = [ cmdFetchResetMaster ];
          workingDir = "/home/phlip9/dev/lexe";
          runOnStartup = true;
        };
      };
  };
  sops.secrets.github-webhook-secret-phlip9-dotfiles = { };
  sops.secrets.github-webhook-secret-phlip9-rbitcoin = { };
  sops.secrets.github-webhook-secret-phlip9-vss-server = { };
  sops.secrets.github-webhook-secret-lexeapp-lexe = { };

  # give agents running on this machine limited access to certain repos, so they
  # can only write to `agent/**` branches.
  services.github-agent-authd = {
    enable = true;
    appId = "2870304";
    appKeyPath = config.sops.secrets.phlip9-github-agent-app-secret-key.path;
  };
  sops.secrets.phlip9-github-agent-app-secret-key = { };

  # =========================================================================
  # Paseo - Agent interface
  #
  # Connect:
  # - Open `https://paseo.phlip9.com`
  # - Direct Connect:
  #   - Endpoint: paseo.phlip9.com
  #   - Port: 443
  #   - SSL: Yes
  #   - Password: <paseo-daemon-password>
  # =========================================================================
  services.paseo = {
    enable = true;
    package = config.phlipPkgs.paseo;

    user = "phlip9";
    group = "users";
    dataDir = "/home/phlip9/.config/paseo";
    hostnames = [
      "paseo.phlip9.com"
    ];

    relay = {
      enable = true;
      mode = "remote";
      host = "relay.paseo.phlip9.com";
      port = 443;
      publicEndpoint = "relay.paseo.phlip9.com:443";
      useTls = true;
      publicUseTls = true;
    };

    relayServer = {
      enable = true;
      domain = "relay.paseo.phlip9.com";
    };

    webUi = {
      enable = true;
      domain = "paseo.phlip9.com";
      publicBaseUrl = "https://paseo.phlip9.com";
    };

    auth.passwordFile = config.sops.secrets.paseo-daemon-password.path;
  };
  sops.secrets.paseo-daemon-password = { };

  # Contain runaway agent procs to the paseo cgroup.
  #
  # 2026-10-29: an agent `cargo test` with an infinite loop leaked ~12G/min,
  # filled RAM + 25G swap, and thrashed the whole machine until I had to hard
  # reset.
  #
  # Hitting MemoryMax triggers a cgroup-local kernel OOM kill of the largest
  # proc (the runaway), not the daemon. OOMPolicy=continue keeps the daemon +
  # other agents alive; the default (stop) would stop the whole unit.
  # No MemoryHigh: w/o an external handler it throttles a runaway into a slow
  # crawl instead of a prompt kill. Cap swap so the cgroup OOMs instead of
  # thrashing the shared swap partition.
  systemd.services.paseo.serviceConfig = {
    MemoryMax = "75%";
    MemorySwapMax = "4G";
    OOMPolicy = "continue";
  };

  # =========================================================================
  # nixbot CI
  # =========================================================================
  # see: doc/nixbot-ci.md
  # see: nixos/mods/nixbot-ci.nix
  services.phlip9-nixbot-ci = {
    enable = true;
    domain = "ci.phlip9.com";

    github = {
      appId = 2746100;
      oauthClientId = "Iv23liE6dM8w5D4JF7Qz";
    };

    cache = {
      url = "https://cache.phlip9.com";
      s3.endpoint = "30faeb30dcb2a77a72fdc0948c99de62.r2.cloudflarestorage.com";
      s3.bucket = "phlip9-nix-cache";
    };
  };
  # PostgreSQL for nixbot CI
  services.postgresql = {
    # Pin the major version to avoid accidentally breaking the DB on nixos
    # version update.
    package = pkgs.postgresql_18;

    # Don't need to expose the postgres to non-local connections
    enableTCPIP = false;
  };
  services.nixbot = {
    # Tune eval and build concurrency for sauna's 6c/12t CPU.
    evalWorkerCount = 4;
    buildConcurrency = 10;

    # Per-repo secrets.json for post-build effects, available as
    # `$HERCULES_CI_SECRETS_JSON`.
    # Format: <https://docs.hercules-ci.com/hercules-ci-agent/secrets-json/>
    effects.perRepoSecretFiles = {
      "github:phlip9/notes-private" =
        config.sops.secrets.ci-secrets-phlip9-notes-private.path;
    };
  };
  sops.secrets.ci-secrets-phlip9-notes-private = { };

  # Nix <= 2.34 daemons answer `querySubstitutablePathInfos` one path and
  # substituter at a time, so nixbot's `nix-eval-jobs --check-cache-status`
  # spent minutes on serial narinfo lookups. Nix 2.35 probes concurrently.
  # TODO(phlip9): drop once nixos-unstable's default `pkgs.nix` is >= 2.35.
  nix.package = pkgs.nixVersions.latest;

  # =========================================================================
  # Observability (o11y)
  # =========================================================================
  # Grafana + VictoriaMetrics + prometheus-*-exporter(s)
  # see: doc/o11y/README.md
  # see: nixos/mods/o11y.nix
  # see: nixos/tests/o11y.nix
  services.phlip9-o11y = {
    enable = true;
    retentionPeriod = "3"; # months
    grafana = {
      domain = "grafana.phlip9.com";
      adminPasswordFile = config.sops.secrets.grafana-admin-password.path;
      secretKeyFile = config.sops.secrets.grafana-secret-key.path;
      secretsManagerKeyFile = config.sops.secrets.grafana-secrets-manager-key.path;

      # Sync dashboards w/ this repo. UI saves commit to master or open a PR.
      # see: doc/o11y/README.md
      gitSync = {
        enable = true;
        # Grafana folder that holds the synced dashboards.
        title = "sauna";
        type = "github";
        github.url = "https://github.com/phlip9/dotfiles";
        github.branch = "master";
        github.path = "nixos/sauna/grafana";
        tokenFile = config.sops.secrets.grafana-git-sync-token.path;
        # The webhook syncs pushes in real time. Poll hourly as a fallback.
        intervalSeconds = 3600;
      };
    };
  };
  sops.secrets.grafana-admin-password = { };
  sops.secrets.grafana-secret-key = { };
  # Grafana reads the key at start only.
  sops.secrets.grafana-secrets-manager-key.restartUnits = [ "grafana.service" ];
  # Re-run setup on rotation; it re-sends the PAT to Grafana.
  sops.secrets.grafana-git-sync-token.restartUnits = [
    "grafana-git-sync-setup.service"
  ];

  environment.systemPackages = [
    # mcp-grafana - Grafana MCP server for claude code (see .mcp.json)
    pkgs.mcp-grafana
  ];
}
