{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "nixos-exporter";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./main.go
      ./main_test.go
    ];
  };
  vendorHash = null;

  ldflags = [
    "-s"
    "-w"
  ];

  env.CGO_ENABLED = "0";

  meta = {
    description = "Prometheus exporter for NixOS boots, generations, and pending reboots";
    homepage = "https://github.com/phlip9/dotfiles";
    mainProgram = "nixos-exporter";
  };
}
