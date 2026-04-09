# Templates for various software (nvim, alacritty, GTK, QT, ...) used by the
# matugen color generation tool.
#
# See: pkgs/matugen.nix
{
  fetchFromGitHub,
  nix-update-script,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "matugen-themes";
  version = builtins.substring 0 8 finalAttrs.src.rev;

  src = fetchFromGitHub {
    owner = "InioX";
    repo = "matugen-themes";
    rev = "15fe2c14b2c2e45207d8dcdf76e1d2e678e49d72";
    hash = "sha256-O6ErEKB3Bho2APerf/p7OMFjGjYaMNnstAxBcYAMC2E=";
    postFetch = ''
      mv $out/templates $TMPDIR/templates
      rm -rf $out
      mkdir $out
      cp -r $TMPDIR/templates/. $out/
    '';
  };

  phases = [ "installPhase" ];

  installPhase = ''
    cp -r $src $out
  '';

  passthru.updateScript = nix-update-script {
    extraArgs = [ "--version=branch=main" ];
  };
})
