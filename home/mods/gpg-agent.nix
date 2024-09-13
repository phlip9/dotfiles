{...}: {
  services.gpg-agent = {
    enable = true;
    enableSshSupport = false;
    enableScDaemon = false;

    defaultCacheTtl = 3 * 24 * 60 * 60;
    maxCacheTtl = 7 * 24 * 60 * 60;

    enableBashIntegration = true;
    enableZshIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = false;
  };
}
