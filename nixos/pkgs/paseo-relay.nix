# Self-hosted zero-knowledge WebSocket relay for Paseo.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "paseo-relay";
  version = "0.5.0";

  src = fetchFromGitHub {
    owner = "zenghongtu";
    repo = "paseo-relay";
    rev = "v${version}";
    hash = "sha256-nu7SkS5DpGQSM+qm/KAEzeX+SqUOsYBdwDZpzG+YJF4=";
  };

  vendorHash = "sha256-0Qxw+MUYVgzgWB8vi3HBYtVXSq/btfh4ZfV/m1chNrA=";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=v${version}"
  ];

  meta = {
    description = "Zero-knowledge WebSocket relay server for Paseo";
    homepage = "https://github.com/zenghongtu/paseo-relay";
    license = lib.licenses.agpl3Plus;
    mainProgram = "paseo-relay";
    platforms = lib.platforms.linux;
  };
}
