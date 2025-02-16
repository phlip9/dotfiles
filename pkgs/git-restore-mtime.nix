# git-restore-mtime: Restore original modification time of files based on the
# date of the most recent commit that modified them.
{
  stdenv,
  fetchFromGitHub,
  python3,
}:
stdenv.mkDerivation {
  name = "git-restore-mtime";
  version = "2024-09-27";

  src = fetchFromGitHub {
    owner = "MestreLion";
    repo = "git-tools";
    rev = "669837eb02f78a75ed250c5d670d9bd7bfc5a51b";
    hash = "sha256-owGWQ3CqyurlVg3NswH0xedeEW/MIJiiU2+5NR1W1jo=";
  };

  buildInputs = [python3];

  installPhase = ''
    mkdir $out
    install -D -t $out/bin $src/git-restore-mtime
  '';
}
