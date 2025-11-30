{
  phlipPkgs,
  pkgs,
  ...
}:
{
  #
  # Window/Display Manager
  #

  # # enable X11 windowing system
  # services.xserver.enable = true;

  # enable GNOME display manager
  services.displayManager = {
    gdm.enable = true;
  };

  # # enable GNOME desktop environment
  # services.desktopManager.gnome.enable = true;

  # # enable COSMIC desktop environment
  # services.desktopManager.cosmic.enable = true;
  # services.displayManager.cosmic-greeter.enable = true;

  # enable niri scrolling tiling wayland compositor
  programs.niri = {
    enable = true;
    package = phlipPkgs.niri;
  };

  # noctalia shell
  services.noctalia-shell = {
    enable = true;
    package = phlipPkgs.noctalia-shell;
  };

  # desktop environment packages
  environment.systemPackages = [
    pkgs.adwaita-icon-theme # mouse cursor and icons
    pkgs.fuzzel # application launcher
    pkgs.gnome-themes-extra # dark adwaita theme
    # pkgs.mako # notification daemon
    # pkgs.swaybg # wallpaper
    # pkgs.swaylock # lock screen
    pkgs.wl-clipboard # clipboard support
    pkgs.xwayland-satellite # niri will support X11 apps if this is in PATH
  ];

  # # top bar
  # programs.waybar.enable = true;

  # lock screen
  security.pam.services.swaylock = { };

  # change system power/performance profiles
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;

  # remove gunk
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
    # pkgs.totem
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
    # gcr-ssh-agent = false; # TODO(phlip9): disable
  };
  services.speechd.enable = false;

  # configure keymap
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
  };

  # fonts
  fonts.packages = [
    pkgs.source-code-pro
  ];

  # # QT
  # qt = {
  #   enable = true;
  #   platformTheme = "gnome";
  #   style = "adwaita";
  # };

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
}
