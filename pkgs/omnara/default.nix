{
  fetchurl,
  lib,
  stdenv,
}:
let
  sources = lib.importJSON ./sources.json;
  source = sources.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "omnara";
  inherit (sources) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/omnara
    chmod +x $out/bin/omnara
    runHook postInstall
  '';

  fixupPhase = lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf --set-rpath "${
      lib.makeLibraryPath [
        stdenv.cc.cc
        stdenv.cc.libc
      ]
    }" "$out/bin/omnara"
    patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$out/bin/omnara"
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Omnara CLI";
    homepage = "https://omnara.com";
    mainProgram = "omnara";
    platforms = [ "x86_64-linux" "aarch64-darwin" ];
  };
}
