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
    rev = "e213a4ce7da91c69af91e1152390bf5cca346636";
    hash = "sha256-J6imkjKcsxsxo6bGYQKVqYa7lcA1G+UM9r9Ay32Cok0=";
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
