{ buildGoModule }:

buildGoModule {
  pname = "dotfiles-webhook";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  ldflags = [
    "-s"
    "-w"
  ];

  env.CGO_ENABLED = "0";

  meta = {
    description = "GitHub webhook listener to auto-sync dotfiles repo";
    homepage = "https://github.com/phlip9/dotfiles";
    mainProgram = "dotfiles-webhook";
  };
}
