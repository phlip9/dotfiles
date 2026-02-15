{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "github-agent-authd";
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
    description = "GitHub App token broker for autonomous coding agents";
    homepage = "https://github.com/phlip9/dotfiles";
    mainProgram = "github-agent-authd";
  };
}
