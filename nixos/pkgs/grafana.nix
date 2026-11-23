# grafana, w/o passthru tests
#
# Silence this annoying eval warning in the upstream NixOS tests:
# `Grafana passwords will be stored as plaintext in the Nix store!`
{ grafana }:
grafana.overrideAttrs (old: {
  passthru = builtins.removeAttrs old.passthru [ "tests" ];
})
