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
    rev = "d880aeec9209ce56134c661c085535f8db5fa332";
    hash = "sha256-aGj3jokh7vcbbQNkjLWHoJddbEbzPvNEM41Yc3lZKEI=";
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
