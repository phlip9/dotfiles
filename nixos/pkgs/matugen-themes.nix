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
    rev = "81dbb64821cd1716371a7590bfab245c0af0d19a";
    hash = "sha256-aZjM+ZsA0arEN6JqM8KnL4jz7Cc9JJaYdtLfRTgl0zI=";
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
