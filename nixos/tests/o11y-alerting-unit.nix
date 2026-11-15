# Offline unit check of sauna's alert rules + Alertmanager routing, in the
# nix sandbox. Checks exactly what sauna deploys:
# - vmalert rules: syntax + templates, then the vmalert-tool unit tests in
#   nixos/mods/o11y/server/tests against the rendered rules file.
# - Alertmanager: config + templates, then which receivers each kind of
#   alert routes to. `routes test` ignores time intervals: a page goes to
#   discord-quiet always, and to discord-page (the @mention) by day.
# Plus sauna's rules w/ a second alerted host (`other`), which sauna doesn't
# deploy: per-host rule tests, and inhibitions in a sandbox Alertmanager.
#
# Run: `just alerting-test`
{
  nixosConfigs,
  pkgs,
}:

let
  inherit (pkgs) lib;
  inherit (nixosConfigs.sauna) config;
  cfgAm = config.services.prometheus.alertmanager;
  yaml = pkgs.formats.yaml { };

  rulesFile = config.environment.etc."vmalert/rules.yml".source;
  # Same content as the nixpkgs module's (not exposed) config file.
  amConfigFile = pkgs.writeText "alertmanager.yml" (
    builtins.toJSON cfgAm.configuration
  );

  # sauna's rules w/ `server.alerting.instances = [ "sauna" "other" ]`.
  # rules.nix only reads config, so no second NixOS eval.
  twoHosts = import ../mods/o11y/server/rules.nix {
    inherit lib;
    config = lib.recursiveUpdate config {
      services.phlip9-o11y.server.alerting.instances = [
        "sauna"
        "other"
      ];
    };
  };
  twoHostsRulesFile = yaml.generate "rules-two-hosts.yml" {
    inherit (twoHosts) groups;
  };

  # Same phlipPkgs as sauna's modules
  inherit (nixosConfigs.sauna._module.args) phlipPkgs;
  inhibitionCheck = phlipPkgs.writeTypedPython3Bin "o11y-inhibition-check" {
  } ./o11y-alerting-unit/inhibition.py;

  # Just the inhibitions, w/ a receiver that never sends.
  twoHostsAmConfigFile = pkgs.writeText "alertmanager-two-hosts.yml" (
    builtins.toJSON {
      route.receiver = "noop";
      receivers = [ { name = "noop"; } ];
      inhibit_rules = twoHosts.inhibitRules;
    }
  );
in
pkgs.runCommand "o11y-alerting-unit"
  {
    nativeBuildInputs = [
      config.services.vmalert.package
      cfgAm.package
    ];
  }
  ''
    # tests/*.yml load `../rules.yml` or `../rules-two-hosts.yml`
    cp ${rulesFile} rules.yml
    cp ${twoHostsRulesFile} rules-two-hosts.yml
    cp -r ${../mods/o11y/server/tests} tests

    vmalert -dryRun -rule=rules.yml -loggerLevel=ERROR
    vmalert -dryRun -rule=rules-two-hosts.yml -loggerLevel=ERROR
    vmalert-tool unittest -loggerLevel=ERROR --files='tests/*.yml'

    amtool check-config ${amConfigFile}

    # route RECEIVERS LABELS...
    route() {
      local receivers=$1
      shift
      echo "route $* -> $receivers"
      amtool config routes test --config.file=${amConfigFile} \
        --verify.receivers="$receivers" "$@"
    }
    route healthchecks-watchdog alertname=Watchdog severity=none
    route discord-quiet,discord-page alertname=MemLow severity=page
    route discord-quiet alertname=TargetDown severity=warn

    # Inhibitions, in a sandbox Alertmanager: ./o11y-alerting-unit/inhibition.py
    ${lib.getExe inhibitionCheck} ${twoHostsAmConfigFile}

    touch $out
  ''
