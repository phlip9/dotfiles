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

    # automatically add ssh keys to host agent after first use.
    addKeysToAgent = "yes";

    # Support OrbStack on macOS
    includes = lib.optionals (pkgs.hostPlatform.isDarwin) [
      "${config.home.homeDirectory}/.orbstack/ssh/config"
    ];

    # Ignore macOS-only options
    extraConfig = lib.mkIf (pkgs.hostPlatform.isDarwin) ''
      IgnoreUnknown UseKeychain
    '';

    # try to share multiple sessions over a single network connection.
    controlMaster = "auto";
    # keep the connection open for this long after initially disconnecting.
    controlPersist = "15m";
    # control socket location
    controlPath =
      if pkgs.hostPlatform.isLinux then
        "\${XDG_RUNTIME_DIR}/ssh-%C.socket"
      else if
        pkgs.hostPlatform.isDarwin
      # macOS: use ~/.ssh dir to avoid this error:
      # ```
      # unix_listener: path "/var/folders/t9/3kwc3f8j5hgd1y5s48ck7jqw0000gn/T//ssh-818c3a884cebb5241ab66a1cc549b3f5051864bf.LGKJdTrUY5vFBcWv"
      #                too long for Unix domain socket
      # ```
      then
        "${config.home.homeDirectory}/.ssh/ssh-%C.socket"
      else
        throw "nix-ssh: error: unrecognized platform";

    matchBlocks = {
      "lexe-dev-sgx" = {
        user = "deploy";
        hostname = "lexe-dev-sgx.uswest.dev.lexe.app";
        port = 22022;
        forwardAgent = true;
      };
      "lexe-prod" = {
        user = "deploy";
        hostname = "lexe-prod.uswest2.prod.lexe.app";
        port = 22022;
      };
      "lexe-prod-www" = {
        user = "deploy";
        hostname = "lexe-prod-www.uswest2.prod.lexe.app";
        port = 22022;
      };
      "lexe-staging-sgx" = {
        user = "deploy";
        hostname = "lexe-staging-sgx.uswest2.staging.lexe.app";
        port = 22022;
      };
      "lexe-staging-esplora" = {
        user = "deploy";
        hostname = "lexe-staging-esplora.uswest2.staging.lexe.app";
        port = 22022;
      };
    };
  };
}
