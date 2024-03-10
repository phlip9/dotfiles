{pkgs, ...}: {
  programs.ssh = {
    enable = true;
    package = pkgs.openssh;

    matchBlocks = {
      "lexe-dev-sgx" = {
        user = "deploy";
        hostname = "lexe-dev-sgx.westus.cloudapp.azure.com";
        port = 22022;
        forwardAgent = true;
      };
    };
  };
}
