# Self-hosted zero-knowledge WebSocket relay for Paseo.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  nix-update-script,
}:

buildGoModule rec {
  pname = "paseo-relay";
  version = "0.5.0-unstable-2026-08-08";

  src = fetchFromGitHub {
    owner = "zenghongtu";
    repo = "paseo-relay";
    rev = "327b7d5f508d920d980c019e0f3e59205ee6052d";
    hash = "sha256-eUhF6mJMbwTxZwEXlqDqMkUEqu1f3j9o7cAg1M6qQbQ=";
  };

  vendorHash = "sha256-0Qxw+MUYVgzgWB8vi3HBYtVXSq/btfh4ZfV/m1chNrA=";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=v${version}"
  ];

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch" ];
  };

  meta = {
    description = "Zero-knowledge WebSocket relay server for Paseo";
    homepage = "https://github.com/zenghongtu/paseo-relay";
    license = lib.licenses.agpl3Plus;
    mainProgram = "paseo-relay";
    platforms = lib.platforms.linux;
  };
}
