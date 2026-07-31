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

  postInstall = ''
    rm -f "$out/bin/fake-mcp"
  '';
}
