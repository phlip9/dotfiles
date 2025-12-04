{
  cargo,
  lib,
  rustc,
  stdenvNoCC,

  name ? "rust-std-vendor",
  hash ? "",
  vendorSrc ? lib.fileset.toSource {
    root = ../rust;
    fileset =
      lib.fileset.difference
        (lib.fileset.unions [
          ../rust/Cargo.lock
          ../rust/Cargo.toml
          ../rust/compiler
          ../rust/library
          ../rust/src/bootstrap
          ../rust/src/build_helper
          ../rust/src/librustdoc
          ../rust/src/rustc-std-workspace
          ../rust/src/rustdoc-json-types
          ../rust/src/tools
        ])
        (
          lib.fileset.unions [
            ../rust/src/tools/cargo
            ../rust/src/tools/rustc-perf
          ]
        );
  },
}:

stdenvNoCC.mkDerivation {
  name = name;
  src = vendorSrc;

  nativeBuildInputs = [
    cargo
    rustc
  ];
  strictDeps = true;

  buildPhase = ''
    runHook preBuild

    CARGO_HOME=$TMPDIR \
    RUSTC_BOOTSTRAP=1 \
    cargo vendor --locked --versioned-dirs \
      --manifest-path $src/Cargo.toml \
      --sync $src/library/Cargo.toml \
      --sync $src/src/bootstrap/Cargo.toml \
      $out

    runHook postBuild
  '';

  dontUnpack = true;
  dontConfigure = true;
  dontInstall = true;
  dontFixup = true;

  outputHash = hash;
  outputHashAlgo = if hash == "" then "sha256" else null;
  outputHashMode = "recursive";
}
