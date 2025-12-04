{
  eza,

  cargo,
  fetchurl,
  lib,
  pkgsBuildBuild,
  pkgsBuildHost,
  pkgsHostTarget,
  rustc,
  stdenv,
  runCommandLocal,

  file,
  python3,
  cmake,
  rustfmt,
  pkg-config,
  openssl,
  xz,
  ninja,

  which,
  libffi,
  removeReferencesTo,
  makeWrapper,

  libiconv,
  zlib,
  llvmPackages,
}:

let
  inherit (lib)
    optionals
    optional
    optionalString
    concatStringsSep
    ;
  # fastCross = true;
  useLLVM = false;
  withBundledLLVM = false;

  llvmSharedFor =
    pkgSet:
    pkgSet.llvmPackages.libllvm.override (
      {
        enableSharedLibraries = true;
      }
      // lib.optionalAttrs (stdenv.targetPlatform.useLLVM or false) {
        # Force LLVM to compile using clang + LLVM libs when targeting pkgsLLVM
        stdenv = pkgSet.stdenv.override {
          allowedRequisites = null;
          cc = pkgSet.pkgsBuildHost.llvmPackages.clangUseLLVM;
        };
      }
    );

  llvmSharedForBuild = llvmSharedFor pkgsBuildBuild;
  llvmSharedForHost = llvmSharedFor pkgsBuildHost;
  llvmSharedForTarget = llvmSharedForHost;

  # For use at runtime
  llvmShared = llvmSharedFor pkgsHostTarget;
in

stdenv.mkDerivation (final: {
  pname = "x86_64-fortanix-unknown-sgx-rust-std";
  # version = "1.91.1";
  version = "1.90.0";

  src = fetchurl {
    url = "https://static.rust-lang.org/dist/rustc-${final.version}-src.tar.gz";
    # hash = "sha256-ONziBdOfYVcSYfBEQjehzp7+y5cOdg2OxNlXr1tEVyM="; # 1.91.1
    hash = "sha256-eZqfnLpO1TUeBxBIvPa1VgdV2QCWSN7zOkB91JYfm34="; # 1.90.0
    # See https://nixos.org/manual/nixpkgs/stable/#using-git-bisect-on-the-rust-compiler
    passthru.isReleaseTarball = true;
  };

  __darwinAllowLocalNetworking = true;

  # rustc complains about modified source files otherwise
  dontUpdateAutotoolsGnuConfigScripts = true;

  # Running the default `strip -S` command on Darwin corrupts the
  # .rlib files in "lib/".
  #
  # See https://github.com/NixOS/nixpkgs/pull/34227
  #
  # Running `strip -S` when cross compiling can harm the cross rlibs.
  # See: https://github.com/NixOS/nixpkgs/pull/56540#issuecomment-471624656
  stripDebugList = [ "bin" ];

  NIX_LDFLAGS = toString (
    # when linking stage1 libstd: cc: undefined reference to `__cxa_begin_catch'
    # This doesn't apply to cross-building for FreeBSD because the host
    # uses libstdc++, but the target (used for building std) uses libc++
    optional (
      stdenv.hostPlatform.isLinux && !withBundledLLVM && !useLLVM
    ) "--push-state --as-needed -lstdc++ --pop-state"
    ++
      optional (stdenv.hostPlatform.isLinux && !withBundledLLVM && useLLVM)
        "--push-state --as-needed -L${llvmPackages.libcxx}/lib -lc++ -lc++abi -lLLVM-${lib.versions.major llvmPackages.llvm.version} --pop-state"
    ++ optional (stdenv.hostPlatform.isDarwin && !withBundledLLVM) "-lc++ -lc++abi"
    ++ optional stdenv.hostPlatform.isDarwin "-rpath ${llvmSharedForHost.lib}/lib"
  );

  RUSTFLAGS = lib.concatStringsSep " " (
    lib.optionals
      (stdenv.hostPlatform.rust.rustcTargetSpec == "x86_64-unknown-linux-gnu")
      [
        # Upstream defaults to lld on x86_64-unknown-linux-gnu, we want to use our linker
        "-Clinker-features=-lld"
        "-Clink-self-contained=-linker"
      ]
  );
  RUSTDOCFLAGS = "-A rustdoc::broken-intra-doc-links";

  # The Rust pkg-config crate does not support prefixed pkg-config executables[1],
  # but it does support checking these idiosyncratic PKG_CONFIG_${TRIPLE}
  # environment variables.
  # [1]: https://github.com/rust-lang/pkg-config-rs/issues/53
  "PKG_CONFIG_${
    builtins.replaceStrings [ "-" ] [ "_" ] stdenv.buildPlatform.rust.rustcTarget
  }" =
    "${pkgsBuildHost.stdenv.cc.targetPrefix}pkg-config";

  configureFlags =
    let
      buildPlatform = stdenv.buildPlatform;
      hostPlatform = stdenv.hostPlatform;
      target = "x86_64-fortanix-unknown-sgx";

      prefixForStdenv = stdenv: "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}";
      ccPrefixForStdenv =
        stdenv:
        "${prefixForStdenv stdenv}${
          if (stdenv.cc.isClang or false) then "clang" else "cc"
        }";
      cxxPrefixForStdenv =
        stdenv:
        "${prefixForStdenv stdenv}${
          if (stdenv.cc.isClang or false) then "clang++" else "c++"
        }";

      ccForBuild = ccPrefixForStdenv pkgsBuildBuild.targetPackages.stdenv;
      cxxForBuild = cxxPrefixForStdenv pkgsBuildBuild.targetPackages.stdenv;
      ccForHost = ccPrefixForStdenv pkgsBuildHost.targetPackages.stdenv;
      cxxForHost = cxxPrefixForStdenv pkgsBuildHost.targetPackages.stdenv;
      # TODO(phlip9): clang/sgxCrossEnvBuildHook?
      ccForTarget = ccForHost;
      cxxForTarget = ccForTarget;

      setBuild = "--set=target.\"${stdenv.buildPlatform.rust.rustcTarget}\"";
      setHost = "--set=target.\"${stdenv.hostPlatform.rust.rustcTarget}\"";
      setTarget = "--set=target.\"${target}\"";
    in
    [
      "--sysconfdir=${placeholder "out"}/etc"
      "--release-channel=stable"
      "--set=build.rustc=${rustc}/bin/rustc"
      "--set=build.cargo=${cargo}/bin/cargo"
      "--enable-rpath"
      "--enable-vendor"
      "--disable-lld"
      "--build=${buildPlatform.rust.rustcTargetSpec}"
      "--host=${hostPlatform.rust.rustcTargetSpec}"
      "--target=${target}"

      "${setBuild}.cc=${ccForBuild}"
      "${setHost}.cc=${ccForHost}"
      "${setTarget}.cc=${ccForTarget}"

      "${setTarget}.linker=${ccForTarget}"
      "${setBuild}.linker=${ccForBuild}"
      "${setHost}.linker=${ccForHost}"

      "${setBuild}.cxx=${cxxForBuild}"
      "${setHost}.cxx=${cxxForHost}"
      "${setTarget}.cxx=${cxxForTarget}"

      "${setBuild}.crt-static=${lib.boolToString stdenv.buildPlatform.isStatic}"
      "${setHost}.crt-static=${lib.boolToString stdenv.hostPlatform.isStatic}"
      # use rustc target default
      # "${setTarget}.crt-static=true"

      # Since fastCross only builds std, it doesn't make sense (and
      # doesn't work) to build a linker.
      "--disable-llvm-bitcode-linker"
    ]
    ++ optionals (!withBundledLLVM) [
      "--enable-llvm-link-shared"
      "${setBuild}.llvm-config=${llvmSharedForBuild.dev}/bin/llvm-config"
      "${setHost}.llvm-config=${llvmSharedForHost.dev}/bin/llvm-config"
      "${setTarget}.llvm-config=${llvmSharedForTarget.dev}/bin/llvm-config"
    ]
    ++ optionals useLLVM [
      # https://github.com/NixOS/nixpkgs/issues/311930
      "--llvm-libunwind=${if withBundledLLVM then "in-tree" else "system"}"
      "--enable-use-libcxx"
    ]
  #
  ;

  # RUSTC_BOOTSTRAP = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage{0,1}-{std,rustc}/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/
    ln -s ${rustc.unwrapped}/lib/rustlib/${stdenv.hostPlatform.rust.rustcTargetSpec}/libstd-*.so build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-std/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/libstd.so
    ln -s ${rustc.unwrapped}/lib/rustlib/${stdenv.hostPlatform.rust.rustcTargetSpec}/librustc_driver-*.so build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/librustc.so
    ln -s ${rustc.unwrapped}/bin/rustc build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/rustc-main
    ln -s ${rustc.unwrapped}/bin/rustc build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage1-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/rustc-main
    touch build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-std/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/.libstd-stamp
    touch build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage{0,1}-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/.librustc-stamp
    python ./x.py --keep-stage=0 --stage=1 build library

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    python ./x.py --keep-stage=0 --stage=1 install library/std

    runHook postInstall
  '';

  # the rust build system complains that nix alters the checksums
  dontFixLibtool = true;

  postPatch = ''
    patchShebangs src/etc

    ${optionalString (!withBundledLLVM) "rm -rf src/llvm"}

    # Useful debugging parameter
    # export VERBOSE=1
  ''
  + lib.optionalString (!(final.src.passthru.isReleaseTarball or false)) ''
    mkdir .cargo
    cat > .cargo/config.toml <<\EOF
    [source.crates-io]
    replace-with = "vendored-sources"
    [source.vendored-sources]
    directory = "vendor"
    EOF
  '';

  # rustc unfortunately needs cmake to compile llvm-rt but doesn't
  # use it for the normal build. This disables cmake in Nix.
  dontUseCmakeConfigure = true;

  depsBuildBuild = [
    pkgsBuildHost.stdenv.cc
    pkg-config
  ];

  nativeBuildInputs = [
    file
    python3
    rustc
    cmake
    which
    libffi
    removeReferencesTo
    pkg-config
    xz
  ];

  buildInputs = [
    openssl
  ]
  ++ optionals stdenv.hostPlatform.isDarwin [
    libiconv
    zlib
  ]
  ++ optional (!withBundledLLVM) llvmShared.lib
  ++ optional (useLLVM && !withBundledLLVM) llvmPackages.libunwind;

  postInstall = ''
    # remove stuff that doesn't make sense for a rust-std only nix package
    rmdir $out/etc
    rm $out/lib/rustlib/install.log $out/lib/rustlib/uninstall.sh \
       $out/lib/rustlib/rust-installer-version $out/lib/rustlib/components
  '';

  outputs = [ "out" ];
  setOutputFlags = false;

  configurePlatforms = [ ];

  enableParallelBuilding = true;

  # requiredSystemFeatures = [ "big-parallel" ];

  passthru = {
    llvm = llvmShared;
    inherit llvmPackages;
    inherit (rustc) tier1TargetPlatforms targetPlatforms badTargetPlatforms;
  };
})
