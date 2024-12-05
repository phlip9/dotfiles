{pkgs, ...}: {
  programs.ssh = {
    enable = true;
    package = pkgs.openssh;

    # automatically add ssh keys to host agent after first use.
    addKeysToAgent = "yes";

    # try to share multiple sessions over a single network connection.
    controlMaster = "auto";
    controlPath =
      if !pkgs.stdenv.isDarwin
      then "\${XDG_RUNTIME_DIR}/ssh-%C"
      else "\${TMPDIR}/ssh-%C";
    # keep the connection open for this long after initially disconnecting.
    controlPersist = "15m";

    matchBlocks = {
      "lexe-dev-sgx" = {
        user = "deploy";
        hostname = "lexe-dev-sgx.westus.cloudapp.azure.com";
        port = 22022;
        forwardAgent = true;
      };
      "lexe-prod" = {
        user = "deploy";
        hostname = "lexe-prod.uswest2.prod.lexe.app";
        port = 22022;
        forwardAgent = true;
      };
      "lexe-staging-sgx" = {
        user = "deploy";
        hostname = "lexe-staging-sgx.uswest2.staging.lexe.app";
        port = 22022;
        forwardAgent = true;
      };
    };
  };
}
