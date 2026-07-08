{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.ssh = {
    enable = true;
    package = pkgs.openssh;

    enableDefaultConfig = false;

    # # Support OrbStack on macOS
    # includes = lib.optionals (pkgs.stdenv.hostPlatform.isDarwin) [
    #   "${config.home.homeDirectory}/.orbstack/ssh/config"
    # ];

    # Ignore macOS-only options
    extraConfig = lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin) ''
      IgnoreUnknown UseKeychain
    '';

    settings = {
      # default config
      "*" = {
        # Formerly default home-manager ssh configs
        Compression = false;
        ForwardAgent = false;
        HashKnownHosts = false;
        ServerAliveCountMax = 3;
        ServerAliveInterval = 0;

        # automatically add ssh keys to host agent after first use.
        AddKeysToAgent = "yes";

        # try to share multiple sessions over a single network connection.
        ControlMaster = "auto";
        # keep the connection open for this long after initially disconnecting.
        ControlPersist = "15m";
        # control socket location
        ControlPath =
          if pkgs.stdenv.hostPlatform.isLinux then
            "\${XDG_RUNTIME_DIR}/ssh-%C.socket"
          else if
            pkgs.stdenv.hostPlatform.isDarwin
          # macOS: use ~/.ssh dir to avoid this error:
          # ```
          # unix_listener: path "/var/folders/t9/3kwc3f8j5hgd1y5s48ck7jqw0000gn/T//ssh-818c3a884cebb5241ab66a1cc549b3f5051864bf.LGKJdTrUY5vFBcWv"
          #                too long for Unix domain socket
          # ```
          then
            "${config.home.homeDirectory}/.ssh/ssh-%C.socket"
          else
            throw "nix-ssh: error: unrecognized platform";
      };

      "lexe-dev" = {
        User = "deploy";
        HostName = "lexe-dev.uswest.dev.lexe.app";
        Port = 22022;
        ForwardAgent = true;
      };
      "lexe-prod" = {
        User = "deploy";
        HostName = "lexe-prod.uswest2.prod.lexe.app";
        Port = 22022;
      };
      "lexe-prod-www" = {
        User = "deploy";
        HostName = "lexe-prod-www.uswest2.prod.lexe.app";
        Port = 22022;
      };
      "lexe-staging-sgx" = {
        User = "deploy";
        HostName = "lexe-staging-sgx.uswest2.staging.lexe.app";
        Port = 22022;
      };
      "lexe-staging-esplora" = {
        User = "deploy";
        HostName = "lexe-staging-esplora.uswest2.staging.lexe.app";
        Port = 22022;
      };
      "omnara1" = {
        User = "phlip9";
        HostName = "omnara1.phlip9.com";
        Port = 22022;
        # ForwardAgent = true;
      };
    };
  };
}
