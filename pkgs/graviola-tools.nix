{
  pkgsCross,
  runCommandLocal,
}: let
  pkgsX86_64 = pkgsCross.gnu64;
  pkgsAarch64 = pkgsCross.aarch64-multiplatform;

  binutilsX86_64 = pkgsX86_64.binutils-unwrapped;
  binutilsAarch64 = pkgsAarch64.binutils-unwrapped;

  gccX86_64 = pkgsX86_64.gcc-unwrapped;
  gccAarch64 = pkgsAarch64.gcc-unwrapped;
in
  runCommandLocal "graviola-tools" {} ''
    mkdir -p $out/bin

    for tool in as objdump; do
      ln -s ${binutilsX86_64}/bin/$tool $out/bin/x86_64-linux-gnu-$tool
      ln -s ${binutilsAarch64}/bin/$tool $out/bin/aarch64-linux-gnu-$tool
    done

    for tool in cpp; do
      ln -s ${gccX86_64}/bin/$tool $out/bin/x86_64-linux-gnu-$tool
      ln -s ${gccAarch64}/bin/$tool $out/bin/aarch64-linux-gnu-$tool
    done
  ''
