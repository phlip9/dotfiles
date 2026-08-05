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
    rev = "530e49100f2710b82dc1c74ba7e05cd8eacb82a0";
    hash = "sha256-HZuoKsMj2XC1gAaa6Dxvjg2d0rKXwk2j+YYLecj3GF0=";
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
