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
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
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
    package = config.boot.kernelPackages.nvidiaPackages.beta;

    # # Use latest drivers if stable and beta fail to build against latest kernel
    # # <https://www.nvidia.com/en-us/drivers/unix/>
    # # <https://github.com/NixOS/nixpkgs/blob/master/pkgs/os-specific/linux/nvidia-x11/default.nix#L74>
    # package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
    #   version = "580.95.05";
    #   sha256_64bit = "sha256-hJ7w746EK5gGss3p8RwTA9VPGpp2lGfk5dlhsv4Rgqc=";
    #   sha256_aarch64 = "sha256-zLRCbpiik2fGDa+d80wqV3ZV1U1b4lRjzNQJsLLlICk=";
    #   openSha256 = "sha256-RFwDGQOi9jVngVONCOB5m/IYKZIeGEle7h0+0yGnBEI=";
    #   settingsSha256 = "sha256-F2wmUEaRrpR1Vz0TQSwVK4Fv13f3J9NJLtBe4UP2f14=";
    #   persistencedSha256 = "sha256-QCwxXQfG/Pa7jSTBB0xD3lsIofcerAWWAHKvWjWGQtg=";
    # };
  };

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
  programs.firefox.enable = true;

  # allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # list packages installed in system profile
  environment.systemPackages = [
    pkgs.alacritty
    pkgs.wl-clipboard
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
