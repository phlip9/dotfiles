# Grafana Pyroscope datasource plugin
#
# Grafana 13.2 moved this datasource out of core into a catalog plugin, which
# Grafana normally preinstalls from grafana.com at startup. The NixOS module
# disables preinstall once `declarativePlugins` is set, and nixpkgs doesn't
# package it, so package the signed grafana.com release here.
{ grafanaPlugins, lib }:

let
  plugin = grafanaPlugins.grafanaPlugin {
    pname = "grafana-pyroscope-datasource";
    # Go backend plugin: one zip per platform
    inherit (lib.importTOML ./sources.toml) version packages;
    meta = {
      description = "Grafana datasource for Pyroscope continuous profiling";
      license = lib.licenses.agpl3Only;
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    };
  };
in
# The helper's default updateScript (`[ <nixpkgs script> pname ]`) writes into
# the read-only nixpkgs source. Wrap it so it updates our ./sources.toml.
plugin.overrideAttrs (prev: {
  passthru = prev.passthru // {
    updateScript = [ ./update.sh ] ++ prev.passthru.updateScript;
  };
})
