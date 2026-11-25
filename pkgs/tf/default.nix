# Render the OpenTofu config and inject backend/provider credentials.
{
  opentofu,
  sops,
  runCommand,
  terranix,
  writeShellApplication,
}:

let
  # Hash the platform-specific provider wrappers from withPlugins offline.
  providerLock =
    runCommand "tf-provider-lock.hcl" { nativeBuildInputs = [ opentofu ]; }
      ''
        ln -s "${terranix.passthru.configTfJson}" config.tf.json
        tofu providers lock -no-color \
          -fs-mirror="${opentofu}/libexec/terraform-providers"
        mv .terraform.lock.hcl "$out"
      '';
in
writeShellApplication {
  name = "tf";
  runtimeInputs = [
    opentofu
    sops
    terranix
  ];
  text = ''
    # sops exec-env does '/bin/sh -c "$command"' and only uses one arg for
    # command, so we need to quote each arg here to passthru correctly.
    args=""
    for arg in "$@"; do
      quoted_arg=''${arg//\'/\'\\\'\'}
      args+=" '$quoted_arg'"
    done

    terranix > config.tf.json

    # Refresh the local lock when the Nix provider build changes.
    ln -sfn "${providerLock}" .terraform.lock.hcl

    exec sops exec-env ops/secrets.yaml "tofu $args"
  '';

  # Validate the rendered config and the pinned provider package in CI.
  passthru.tests.tf-validate-config =
    runCommand "tf-validate-config"
      {
        nativeBuildInputs = [ opentofu ];
      }
      ''
        ln -s "${terranix.passthru.configTfJson}" config.tf.json
        ln -s "${providerLock}" .terraform.lock.hcl

        tofu init -backend=false -input=false -lockfile=readonly -no-color
        tofu validate -no-color

        touch $out
      '';
}
