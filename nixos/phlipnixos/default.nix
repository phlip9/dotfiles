{
  config,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
  ];

  # disabledModules = [
  #   (modulesPath + "/services/hardware/interception-tools.nix")
  # ];

  # bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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

  #
  # Nix
  #

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  #
  # Window/Display Manager
  #

  # # enable X11 windowing system
  # services.xserver.enable = true;

  # enable GNOME desktop environment
  services.desktopManager.gnome.enable = true;
  services.displayManager = {
    gdm.enable = true;
    autoLogin = {
      enable = true;
      user = "phlip9";
    };
  };

  # remove some gnome gunk
  environment.gnome.excludePackages = [
    pkgs.decibels
    pkgs.epiphany # remove this if things break
    pkgs.gnome-calculator
    pkgs.gnome-calendar
    pkgs.gnome-characters
    pkgs.gnome-clocks
    pkgs.gnome-connections
    pkgs.gnome-contacts
    pkgs.gnome-logs
    pkgs.gnome-maps
    pkgs.gnome-music
    pkgs.gnome-software
    pkgs.gnome-system-monitor
    pkgs.gnome-text-editor
    pkgs.gnome-tour
    pkgs.gnome-weather
    pkgs.orca
    pkgs.simple-scan
    pkgs.snapshot
    #pkgs.totem
    pkgs.yelp
  ];
  programs.evince.enable = false;
  programs.geary.enable = false;
  services.gnome = {
    gnome-online-accounts.enable = false;
    gnome-remote-desktop.enable = false;
    localsearch.enable = false;
    rygel.enable = false;
    tinysparql.enable = false;
  };

  # # enable COSMIC DE
  # services.desktopManager.cosmic.enable = true;
  # services.displayManager.cosmic-greeter.enable = true;

  # Configure keymap
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # disable CUPS. don't need printing.
  services.printing.enable = false;

  # enable sound with pipewire
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # fonts
  fonts.packages = [
    pkgs.source-code-pro
  ];

  # caps2esc
  services.xremap = {
    enable = true;
    extraArgs = [
      "--watch"
      "--device=daskeyboard"
    ];
    config = # yaml
      ''
        modmap:
          - name: CapsLock to Ctrl/Esc
            remap:
              CAPSLOCK:
                held: LEFTCTRL
                alone: ESC
                free_hold: true
      '';
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

    # stable (v570.153.02) and beta (575.64.05) fail to build against kernel v6.17.0
    # package = config.boot.kernelPackages.nvidiaPackages.beta;
    # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/os-specific/linux/nvidia-x11/default.nix#L74>
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "580.95.05";
      sha256_64bit = "sha256-hJ7w746EK5gGss3p8RwTA9VPGpp2lGfk5dlhsv4Rgqc=";
      sha256_aarch64 = "sha256-zLRCbpiik2fGDa+d80wqV3ZV1U1b4lRjzNQJsLLlICk=";
      openSha256 = "sha256-RFwDGQOi9jVngVONCOB5m/IYKZIeGEle7h0+0yGnBEI=";
      settingsSha256 = "sha256-F2wmUEaRrpR1Vz0TQSwVK4Fv13f3J9NJLtBe4UP2f14=";
      persistencedSha256 = "sha256-QCwxXQfG/Pa7jSTBB0xD3lsIofcerAWWAHKvWjWGQtg=";
    };
  };

  #
  # User
  #

  users.users.phlip9 = {
    isNormalUser = true;
    description = "Philip Kannegaard Hayes";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = [ ];
  };

  # install firefox
  programs.firefox.enable = true;

  # allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # list packages installed in system profile
  environment.systemPackages = [
    pkgs.alacritty
    pkgs.wl-clipboard

    # nvtop
    pkgs.nvtopPackages.nvidia

    # video player
    config.phlipPkgs.mpv
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
