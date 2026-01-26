# rage-age-compat - provide an age shim to the rage binary
{ stdenv, rage }:

stdenv.mkDerivation {
  pname = "rage-age-compat";
  version = "0.1.0";

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    ln -s ${rage}/bin/rage $out/bin/age
    ln -s ${rage}/bin/rage-keygen $out/bin/age-keygen
  '';
}
