# Grafana Canvas panel plugin
#
# Grafana 13 loads Canvas as a standalone catalog plugin (`[plugin.canvas]
# as_external = true` in defaults.ini) and skips the core copy, which goes
# away in Grafana 14. Grafana normally preinstalls it from grafana.com, but the
# NixOS module disables preinstall once `declarativePlugins` is set, and
# nixpkgs doesn't package it, so package the signed grafana.com release here.
{ grafanaPlugins, lib }:

let
  plugin = grafanaPlugins.grafanaPlugin {
    # grafana.com plugin slug. The download URLs and update script key off it.
    pname = "canvas";
    # Frontend-only panel: one zip for all platforms
    inherit (lib.importTOML ./sources.toml) version packages;
    meta = {
      description = "Grafana panel for custom visualizations over images";
      license = lib.licenses.agpl3Only;
    };
  };
in
# The helper's default updateScript (`[ <nixpkgs script> pname ]`) writes into
# the read-only nixpkgs source. Wrap it so it updates our ./sources.toml.
plugin.overrideAttrs (prev: {
  passthru = prev.passthru // {
    updateScript = [
      ../grafana-plugin-update.sh
      ./.
    ]
    ++ prev.passthru.updateScript;
  };
})
