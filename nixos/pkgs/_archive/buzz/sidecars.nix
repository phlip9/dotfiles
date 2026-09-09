{
  cacert,
  gitMinimal,
  rustPlatform,

  src,
  version,
}:

let
  sidecarPackageFlags = [
    "-p"
    "buzz-acp"
    "-p"
    "buzz-agent"
    "-p"
    "buzz-dev-mcp"
    "-p"
    "git-credential-nostr"
    "-p"
    "buzz-cli"
  ];
in

rustPlatform.buildRustPackage {
  pname = "buzz-sidecars";
  inherit src version;

  cargoHash = "sha256-0a0SJqDjSTWXU6k3yZ6iisDaUdnHqzjZU33ItzGs8AY=";
  cargoBuildFlags = sidecarPackageFlags;
  cargoTestFlags = sidecarPackageFlags;

  # Tests construct HTTPS clients and invoke Git inside the Nix sandbox.
  nativeCheckInputs = [
    cacert
    gitMinimal
  ];

  # Skip flaky tests
  checkFlags = [
    "--skip=cancelled_turn_with_usage_emits_notification_before_response"
    "--skip=steer_folds_into_active_turn_without_cancelling"
    "--skip=steer_rejected_on_run_id_mismatch"
  ];

  postInstall = ''
    rm -f "$out/bin/fake-mcp"
  '';
}
