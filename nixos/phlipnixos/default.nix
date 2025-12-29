{
  config,
  phlipPkgs,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../profiles/desktop.nix
  ];

  # disabledModules = [
  #   (modulesPath + "/services/hardware/interception-tools.nix")
  # ];

  # bootloader
  boot.loader = {
    # Enable Limine bootloader with secure boot
    # See: <../../doc/SECURE-BOOT.md>
    limine = {
      enable = true;
      efiSupport = true;
      secureBoot.enable = true;
      maxGenerations = 8;

      style = {
        wallpapers = [
          (pkgs.fetchurl {
            url = "https://phlip9.com/notes/__pub/sand_dunes_cropped.jpeg";
            hash = "sha256-PITohebOHZ68rWOXUbpcXYy8rqHq7/atdY66zff91cQ=";
          })
        ];
        wallpaperStyle = "centered";
        backdrop = "DEC0B2";
        interface.brandingColor = 7;
        graphicalTerminal = {
          # black, red, green, brown, blue, magenta, cyan, gray
          palette = "0D0C0C;C4746E;8A9A7B;C4B28A;8BA4B0;A292A3;8EA4A2;C8C093";
          brightPalette = "A6A69C;E46876;87A987;E6C384;7FB4CA;938AA9;7AA89F;C5C9C5";
          foreground = "DEDDD3";
          background = "12120F";
          brightForeground = "C8C093";
          brightBackground = "2D4F67";
          margin = 196;
          marginGradient = 0;
        };
      };
    };
    efi.canTouchEfiVariables = true;
    timeout = 2;
  };

  # use latest kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "phlipnixos";
  networking.wireless.enable = false;
  networking.networkmanager.enable = true;

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # firmware update daemon
  services.fwupd = {
    enable = true;
  };

  # enable TPM2.0 device with user-space resource manager daemon
  security.tpm2 = {
    enable = true;
    abrmd.enable = true;
    pkcs11.enable = true;

    tctiEnvironment.enable = true;
    tctiEnvironment.interface = "tabrmd";
  };

  #
  # Nix
  #

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # trying out lix.systems
  nix.package = pkgs.lixPackageSets.stable.lix;
  nixpkgs.overlays = [
    # TODO(phlip9): figure out why infinite recursion: <https://git.lix.systems/lix-project/lix/issues/980>
    # or use more sophisticated overlay like: <https://git.lix.systems/lix-project/nixos-module/src/branch/main/overlay.nix>
    (final: prev: {
      nix = prev.lixPackageSets.stable.lix;
    })
  ];

  # Run non-NixOS binaries
  programs.nix-ld = {
    enable = true;
    libraries = [
      config.hardware.nvidia.package
      pkgs.alsa-lib
      pkgs.libglvnd
    ];
  };

  #
  # Nvidia graphics drivers
  #

  # enable hardware acceleration
  hardware.graphics.enable = true;
  # load nvidia drivers for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];

  nixpkgs.config.nvidia.acceptLicense = true;

  hardware.nvidia = {
    # use proprietary drivers. OSS drivers only support Turing+ (1080 Ti /
    # Pascal is too old)
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.production;

    # # 590+ no longer supports 1080 Ti / Pascal
    # package = config.boot.kernelPackages.nvidiaPackages.beta;

    # # Use latest drivers if stable and beta fail to build against latest kernel
    # # <https://www.nvidia.com/en-us/drivers/unix/>
    # # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/os-specific/linux/nvidia-x11/default.nix#L74>
    # package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
    #   version = "580.119.02";
    #   sha256_64bit = "sha256-gCD139PuiK7no4mQ0MPSr+VHUemhcLqerdfqZwE47Nc=";
    #   sha256_aarch64 = "sha256-eYcYVD5XaNbp4kPue8fa/zUgrt2vHdjn6DQMYDl0uQs=";
    #   openSha256 = "sha256-l3IQDoopOt0n0+Ig+Ee3AOcFCGJXhbH1Q1nh1TEAHTE=";
    #   settingsSha256 = "sha256-sI/ly6gNaUw0QZFWWkMbrkSstzf0hvcdSaogTUoTecI=";
    #   persistencedSha256 = "sha256-j74m3tAYON/q8WLU9Xioo3CkOSXfo1CwGmDx/ot0uUo=";
    # };
  };

  # Error loudly when the nvidia driver version gets too new.
  assertions = [
    (
      let
        version = config.hardware.nvidia.package.version;
        isDriver1080TiCompat = (builtins.compareVersions version "581.0.0") == -1;
      in
      {
        assertion = isDriver1080TiCompat;
        message = "nvidia driver is probably not compatible with 1080 Ti: ${version}";
      }
    )
  ];

  #
  # User
  #

  users.users.phlip9 = {
    isNormalUser = true;
    description = "Philip Kannegaard Hayes";
    extraGroups = [
      "i2c"
      "input"
      "networkmanager"
      "plugdev"
      "video"
      "wheel"
    ];
    packages = [ ];
  };

  # sudo-rs - memory-safe sudo
  security.sudo.enable = false;
  security.sudo-rs = {
    enable = true;
    # only users in "wheel" can even run `sudo`
    execWheelOnly = true;
  };

  # FDE + single-user => can just use auto-login
  services.displayManager.autoLogin = {
    enable = true;
    user = "phlip9";
  };

  # TODO(phlip9): router is handling *.lan allocations, do we still need this?
  # # mDNS
  # services.avahi = {
  #   enable = true;
  #   # enable NSS plugin so local applications see *.local DNS names
  #   nssmdns4 = true;
  # };

  # # TODO(phlip9): more robust brightness control
  # # <https://discourse.nixos.org/t/brightness-control-of-external-monitors-with-ddcci-backlight/8639/23>
  # #
  # # Writes to the monitor brightness really should be intermediated by a
  # # persistent service vs. writing with ddcutil directly.
  # # Either use something like ddccontrol or ddcutil-service and update
  # # noctalia-shell, or maybe the ddcci_backlight driver handles this
  # # correctly?
  # services.ddccontrol.enable = true;

  # install firefox
  programs.firefox = {
    enable = true;

    # set firefox default config json ("organisation policy")
    # <https://mozilla.github.io/policy-templates/>
    policies = {
      # manage FF extensions
      # - check about:support for extension/add-on ID strings.
      ExtensionSettings = {
        # uBlock Origin
        "uBlock0@raymondhill.net" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
          installation_mode = "normal_installed";
        };
        # BetterTTV - Twitch/Youtube emotes, QoL, etc
        "firefox@betterttv.net" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/betterttv/latest.xpi";
          installation_mode = "normal_installed";
        };
        # Ctrl+Number to switch tabs
        "{84601290-bec9-494a-b11c-1baa897a9683}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/ctrl-number-to-switch-tabs/latest.xpi";
          installation_mode = "normal_installed";
        };
        # Sort Tabs
        "{cd89151d-78f2-4f57-9a91-52c0738028f2}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/sort-tabs-00/latest.xpi";
          installation_mode = "normal_installed";
        };
        # 1Password
        "{d634138d-c276-4fc8-924b-40a0ea21d284}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/1password-x-password-manager/latest.xpi";
          installation_mode = "normal_installed";
        };
        # Vimium
        "{d7742d87-e61d-4b78-b8a1-b469842139fa}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/vimium_ff/latest.xpi";
          installation_mode = "normal_installed";
        };
      };

      # improve 1Password integration by disabling builtin password manager
      DisableFormHistory = true;
      OfferToSaveLogins = false;
      PasswordManagerEnabled = false;
    };
  };

  # allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # list packages installed in system profile
  environment.systemPackages = [
    # terminal
    pkgs.alacritty

    # copy/paste
    pkgs.wl-clipboard

    # Signal messenger
    pkgs.signal-desktop

    # nvtop
    pkgs.nvtopPackages.nvidia

    # video player
    phlipPkgs.mpv
  ];

  # enable 1Password
  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "phlip9" ];
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
}
