# Grafana Pyroscope datasource plugin
#
# Grafana 13.2 moved this datasource out of core into a catalog plugin, which
# Grafana normally preinstalls from grafana.com at startup. The NixOS module
# disables preinstall once `declarativePlugins` is set, and nixpkgs doesn't
# package it, so package the signed grafana.com release here.
{ grafanaPlugins, lib }:

grafanaPlugins.grafanaPlugin rec {
  pname = "grafana-pyroscope-datasource";
  version = "13.0.10";
  # Go backend plugin: one zip per platform
  zipHash = {
    x86_64-linux = "sha256-JXTIvhPWHQ76QIfqLiE8c0a6iHRGKwSB2rzT+hwffqc=";
    aarch64-linux = "sha256-Yn7nkAKB1psBGVNFyHDaIcBrk2vEpbY3WLh4zqR5KiM=";
    aarch64-darwin = "sha256-Ow2pSrhkA/EaCFG0cA7kcyIl5mDTO+03Dsk1X1BQS40=";
  };
  meta = {
    description = "Grafana datasource for Pyroscope continuous profiling";
    license = lib.licenses.agpl3Only;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = lib.attrNames zipHash;
  };
}
