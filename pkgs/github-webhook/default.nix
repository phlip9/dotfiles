{
  buildGoModule,
  gitMinimal,
  lib,
}:

buildGoModule {
  pname = "github-webhook";
  version = "0.2.0";

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

  nativeCheckInputs = [ gitMinimal ];

  meta = {
    description = "GitHub webhook listener for multi-repo command execution";
    homepage = "https://github.com/phlip9/dotfiles";
    mainProgram = "github-webhook";
  };
}
