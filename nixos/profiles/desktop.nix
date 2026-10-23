{
  config,
  lib,
  phlipPkgsNixos,
  pkgs,
  ...
}:
{
  imports = [ ./nix-sources.nix ];

  #
  # Kernel/Boot
  #

  # don't timeout to emergency shell while waiting for LUKS disk encryption
  # password
  boot.initrd.systemd.settings.Manager.DefaultDeviceTimeoutSec = "infinity";

  # Ensure a clean & sparkling /tmp on fresh boots.
  boot.tmp.cleanOnBoot = true;

  # Limit max journal size
  services.journald.settings.Journal.SystemMaxUse = "512M";

  #
  # Nix
  #

  phlip9.nix-cache.enable = true;

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
        initial_session = lib.mkIf autoLogin.enable {
          command = niri-session;
          user = autoLogin.user;
          service = "greetd-autologin";
        };
        # After logout/crash, require PAM auth instead of reopening a desktop.
        # agreety is bundled with greetd; no extra greeter package is needed.
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
    # agreety writes prompts to stderr; the text-greeter preset journals it.
    StandardError = lib.mkForce "tty";
    # agreety exits after five bad attempts; greetd can then exit with 0.
    # /run/greetd.run survives restarts, preventing another initial autologin.
    Restart = lib.mkForce "always";
  };

  # greetd shares root's kernel keyring. Isolate every session before a
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

  #
  # Window/Display Manager
  #

  # # enable X11 windowing system
  # services.xserver.enable = true;

  # # enable GNOME display manager
  # services.displayManager = {
  #   gdm.enable = true;
  # };

  # # enable GNOME desktop environment
  # services.desktopManager.gnome.enable = true;

  # # enable COSMIC desktop environment
  # services.desktopManager.cosmic.enable = true;
  # services.displayManager.cosmic-greeter.enable = true;

  # niri scrolling tiling wayland compositor
  # - docs: <https://github.com/YaLTeR/niri/wiki/Getting-Started>
  programs.niri.enable = true;

  # noctalia wayland desktop shell
  # - repo: <https://github.com/noctalia-dev/noctalia>
  # - docs: <https://docs.noctalia.dev/noctalia/>
  programs.noctalia = {
    enable = true;
    systemd.enable = true;
    recommendedServices.enable = false;
  };

  # desktop environment packages
  environment.systemPackages = with pkgs; [
    # oculante # fast and simple image viewer and editor (broken)
    adwaita-icon-theme # mouse cursor and icons
    app2unit # have noctalia launcher open apps in their own units
    apple-cursor # macOS-looking cursor
    eog # GNOME image viewer
    ffmpegthumbnailer # nautilus uses this for video thumbnails
    fuzzel # application launcher
    gnome-themes-extra # dark adwaita theme
    gradia # pretty screenshots
    libnotify # send desktop notifications from CLI
    losslesscut-bin # lossless video/audio editing
    nautilus # file chooser
    wl-clipboard # clipboard support
    xwayland-satellite # niri will support X11 apps if this is in PATH
  ];

  # change system power/performance profiles
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;

  # (currently) required for xdg-document-portal
  #
  # NixOS 26.11 just this opt-in and FUSE consumers in NixOS upstream haven't
  # explicitly added dependencies on FUSE, so need to enable this here for now.
  # can probably remove this in the future.
  programs.fuse.enable = true;

  # # remove gnome gunk
  # environment.gnome.excludePackages = [
  #   pkgs.decibels
  #   pkgs.epiphany # remove this if things break
  #   pkgs.gnome-calculator
  #   pkgs.gnome-calendar
  #   pkgs.gnome-characters
  #   pkgs.gnome-clocks
  #   pkgs.gnome-connections
  #   pkgs.gnome-contacts
  #   pkgs.gnome-logs
  #   pkgs.gnome-maps
  #   pkgs.gnome-music
  #   pkgs.gnome-software
  #   pkgs.gnome-system-monitor
  #   pkgs.gnome-text-editor
  #   pkgs.gnome-tour
  #   pkgs.gnome-weather
  #   pkgs.orca
  #   pkgs.simple-scan
  #   pkgs.snapshot
  #   # pkgs.totem
  #   pkgs.yelp
  # ];
  # programs.evince.enable = false;
  # programs.geary.enable = false;
  # services.gnome = {
  #   gnome-online-accounts.enable = false;
  #   gnome-remote-desktop.enable = false;
  #   localsearch.enable = false;
  #   rygel.enable = false;
  #   tinysparql.enable = false;
  #   # gcr-ssh-agent = false; # TODO(phlip9): disable
  # };
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
  fonts = {
    packages = [
      pkgs.inter
      pkgs.merriweather
      pkgs.noto-fonts-monochrome-emoji
      pkgs.source-code-pro
    ];
    fontconfig = {
      # my default font stack
      defaultFonts = {
        monospace = [ "Source Code Pro" ];
        sansSerif = [ "Inter" ];
        serif = [ "Merriweather" ];
        emoji = [ "Noto Emoji" ];
      };
      # LCD subpixel rendering for my standard 108 DPI LCD display
      subpixel = {
        rgba = "rgb";
        lcdfilter = "light";
      };
      # disable ugly, legacy bitmap fonts
      allowBitmaps = false;
      # # TODO(phlip9): experiment
      # hinting.style = "medium";
      # hinting.style = "full";
    };
  };

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
