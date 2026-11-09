# multios-usb - USB boot directly from .iso images
# PR: <https://github.com/NixOS/nixpkgs/pull/563389>
{
  lib,
  stdenv,
  fetchFromGitHub,
  makeBinaryWrapper,
  nix-update-script,
  bash,
  coreutils,
  gnugrep,
  gnused,
  gnutar,
  xz,
  bzip2,
  rsync,
  gptfdisk,
  util-linux,
  exfatprogs,
  dosfstools,
  e2fsprogs,
  ntfs3g,
}:

let
  runtimeDeps = [
    bash
    coreutils
    gnugrep
    gnused
    gnutar
    xz
    bzip2
    rsync
    gptfdisk
    util-linux
    exfatprogs
    dosfstools
    e2fsprogs
    ntfs3g
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "multios-usb";
  version = "0.15.0";

  src = fetchFromGitHub {
    owner = "Mexit";
    repo = "MultiOS-USB";
    tag = "v${finalAttrs.version}";
    hash = "sha256-jZ+bPQKc45fiIAbTUeNwpla6yQXBUyICeciWcIsauR4=";
  };

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  # Let fixup pin the installer's Bash shebang with strictDeps enabled.
  buildInputs = [ bash ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/multios-usb $out/bin
    cp -r . $out/share/multios-usb
    chmod +x $out/share/multios-usb/multios-usb.sh

    makeWrapper $out/share/multios-usb/multios-usb.sh $out/bin/multios-usb \
      --chdir $out/share/multios-usb \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Boot operating systems directly from ISO/WIM images";
    homepage = "https://github.com/Mexit/MultiOS-USB";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    broken = stdenv.hostPlatform.isDarwin;
    mainProgram = "multios-usb";
  };
})
