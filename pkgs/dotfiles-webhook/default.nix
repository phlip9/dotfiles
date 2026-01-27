{
  buildGoModule,
  gitMinimal,
  lib,
}:

buildGoModule {
  pname = "dotfiles-webhook";
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

  nativeCheckInputs = [ gitMinimal ];

  meta = {
    description = "GitHub webhook listener to auto-sync dotfiles repo";
    homepage = "https://github.com/phlip9/dotfiles";
    mainProgram = "dotfiles-webhook";
  };
}
