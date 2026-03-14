# git-restore-mtime: Restore original modification time of files based on the
# date of the most recent commit that modified them.
{
  fetchFromGitHub,
  nix-update-script,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "git-restore-mtime";
  version = "2025.08";

  src = fetchFromGitHub {
    owner = "MestreLion";
    repo = "git-tools";
    tag = "v${finalAttrs.version}";
    hash = "sha256-DuhvepcDXk+UTFbvmv5V/EGP9ZEnHBYk7ARm/z0gTLY=";
  };

  buildInputs = [ python3 ];

  installPhase = ''
    mkdir $out
    install -D -t $out/bin $src/git-restore-mtime
  '';

  passthru.updateScript = nix-update-script { };
})
