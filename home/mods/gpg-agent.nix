{
  lib,
  pkgs,
  ...
}: {
  services.gpg-agent = {
    enable = true;
    enableSshSupport = false;
    enableScDaemon = false;

    enableBashIntegration = true;
    enableZshIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = false;

    pinentry.package = lib.mkIf (pkgs.hostPlatform.isLinux) pkgs.pinentry-gnome3;

    defaultCacheTtl = 3 * 24 * 60 * 60;
    maxCacheTtl = 7 * 24 * 60 * 60;
  };
}
