{
  opentofu,
  sops,
  terranix,
  writeShellApplication,
}:

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

    exec sops exec-env ops/secrets.yaml "tofu $args"
  '';
}
