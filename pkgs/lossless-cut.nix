{
  fetchurl,
  writeShellScriptBin,
}:
let
  version = "3.65.0";
  appImageBin = fetchurl {
    url = "https://github.com/mifi/lossless-cut/releases/download/v${version}/LosslessCut-linux-x86_64.AppImage";
    hash = "sha256-c9IBjbgsBmUsFl10evxXuCyZ92/Y9MWJyyUMjQP6FtU=";
    executable = true;
  };
in
writeShellScriptBin "lossless-cut" ''
  exec "${appImageBin}" "$@"
''
