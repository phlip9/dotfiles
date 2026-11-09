# Offline unit check of sauna's alert rules + Alertmanager routing, in the
# nix sandbox. Checks exactly what sauna deploys:
# - vmalert rules: syntax + templates, then the vmalert-tool unit tests in
#   nixos/mods/o11y/tests against the rendered rules file.
# - Alertmanager: config + templates, then which receivers each kind of
#   alert routes to. `routes test` ignores time intervals: a page goes to
#   discord-quiet always, and to discord-page (the @mention) by day.
#
# Run: `just alerting-test`
{
  nixosConfigs,
  pkgs,
}:

let
  inherit (nixosConfigs.sauna) config;
  cfgAm = config.services.prometheus.alertmanager;

  rulesFile = config.environment.etc."vmalert/rules.yml".source;
  # Same content as the nixpkgs module's (not exposed) config file.
  amConfigFile = pkgs.writeText "alertmanager.yml" (
    builtins.toJSON cfgAm.configuration
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
    # tests/*.yml load `../rules.yml`
    cp ${rulesFile} rules.yml
    cp -r ${../mods/o11y/tests} tests

    vmalert -dryRun -rule=rules.yml -loggerLevel=ERROR
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

    touch $out
  ''
