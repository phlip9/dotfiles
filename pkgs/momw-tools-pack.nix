# MOMW (Modding OpenMW) Tools Pack
{
  fetchzip,
  lib,
  makeWrapper,
  p7zip,
  runCommandLocal,
  unrar,
}: let
  pname = "momw-tools-pack";
  version = "20250129";

  # tell nixpkgs to STFU about unfree packages
  unrarIgnoreUnfree = unrar.overrideAttrs {
    meta = {};
  };
in
  runCommandLocal "${pname}-${version}" {
    bins = fetchzip {
      pname = pname;
      version = version;
      url = "https://gitlab.com/modding-openmw/momw-tools-pack/-/jobs/8991493159/artifacts/raw/momw-tools-pack-linux.tar.gz";
      hash = "sha256-bp4BNJuGf2nZAGxIdesRQFSH3zu9QHxmH9p/+arUh1M=";
    };

    nativeBuildInputs = [
      makeWrapper
    ];
  } ''
    mkdir -p "$out/bin"
    ln -s "$bins/delta_plugin" "$bins/groundcoverify" "$bins/momw-configurator-linux-amd64" \
      "$bins/openmw-validator-linux-amd64" "$bins/s3lightfixes" "$bins/tes3cmd" "$bins/umo" \
      "$out/bin/"

    wrapProgram "$out/bin/umo" \
      --prefix PATH : ${lib.makeBinPath [p7zip unrarIgnoreUnfree]}
  ''
