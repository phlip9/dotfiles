{
  callPackage,
  cargo,
  cmake,
  fetchFromGitHub,
  file,
  glibc,
  lib,
  llvmPackages,
  ninja,
  pkgsBuildBuild,
  pkgsBuildHost,
  python3,
  rustc,
  stdenv,
  stdenvNoCC,
  which,
}:

let
  # package containing `llvm-config` so we can avoid rebuilding all of LLVM
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

  # Use plain, unwrapped (not nixpkgs wrapped) compilers and binutils.
  bintools-unwrapped = llvmPackages.bintools-unwrapped;
  clang-unwrapped = llvmPackages.clang-unwrapped;
  lld = llvmPackages.lld;
  libcxx = llvmPackages.libcxx.dev;

  # snmalloc needs c++ std headers to compile. We have to configure them a bit
  # to manually enable/disable some features that aren't available in SGX or
  # aren't detected automatically.
  libcxx-dev = stdenvNoCC.mkDerivation {
    pname = "${libcxx.pname}-cfg-sgx";
    version = libcxx.version;
    src = libcxx.dev;

    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/include
      shopt -s extglob
      cp -R $src/include/c++/v1/!(__config_site) $out/include
      shopt -u extglob
    ''
    + lib.optionalString (lib.versionAtLeast libcxx.version "20") ''
      substitute $src/include/c++/v1/__config_site $out/include/__config_site \
        --replace-fail '#define _LIBCPP_HAS_FILESYSTEM 1' '#define _LIBCPP_HAS_FILESYSTEM 0' \
        --replace-fail '#define _LIBCPP_HAS_LOCALIZATION 1' '#define _LIBCPP_HAS_LOCALIZATION 0' \
        --replace-fail '#define _LIBCPP_HAS_TERMINAL 1' '#define _LIBCPP_HAS_TERMINAL 0' \
        --replace-fail '#define _LIBCPP_HAS_THREAD_API_PTHREAD 0' '#define _LIBCPP_HAS_THREAD_API_PTHREAD 1'
    ''
    + lib.optionalString (lib.versionOlder libcxx.version "20") ''
      substitute $src/include/c++/v1/__config_site $out/include/__config_site \
        --replace-fail '/* #undef _LIBCPP_HAS_NO_FILESYSTEM */' '#define _LIBCPP_HAS_NO_FILESYSTEM 1' \
        --replace-fail '/* #undef _LIBCPP_HAS_NO_LOCALIZATION */' '#define _LIBCPP_HAS_NO_LOCALIZATION 1' \
        --replace-fail '/* #undef _LIBCPP_HAS_THREAD_API_PTHREAD */' '#define _LIBCPP_HAS_THREAD_API_PTHREAD 1'
    '';
  };

  # We run on min. Ice Lake (60_6AH) which mitigates LVI in hardware. Disable
  # lvi-cfi and lvi-load-hardening since these have a HUGE performance cost
  # (5-20x). Still need retpolines to mitigate Spectre_v2, just at a much
  # lower cost (2-50%).
  rustflagsSgx = builtins.concatStringsSep " " [
    "-Zretpoline=yes"
    "-Ctarget-feature=-lvi-cfi,-lvi-load-hardening,+adx,+aes,+pclmulqdq,+sha,+vaes"
    "-Ctarget-cpu=x86-64-v3"
  ];

  # CFLAGS for SGX target
  cflagsSgx = builtins.concatStringsSep " " [
    # as far as libc/libcxx/cmake are concerned, SGX == no-std ELF target
    "-D__ELF__"
    "-DCMAKE_SYSTEM_NAME=Generic-ELF"

    # target min. Ice Lake
    "-march=x86-64-v3"

    # silence snmalloc warning
    "-Wno-missing-template-arg-list-after-template-kw"

    # replace LVI CFI/hardening w/ RET-polines. See above.
    # "-mlvi-hardening"
    # "-mllvm=-x86-experimental-lvi-inline-asm-hardening"
    # TODO: <src/llvm-project/llvm/include/llvm/TargetParser/X86TargetParser.def>
    "-mno-lvi-cfi"
    "-mno-lvi-hardening"
    "-mretpoline"

    # include compiler platform / intrinsics headers
    "-resource-dir ${clang-unwrapped.lib}/lib/clang/${lib.versions.major clang-unwrapped.version}"

    # include libc headers
    "-idirafter${glibc.dev}/include"
  ];

  # CXXFLAGS for SGX target
  cxxflagsSgx = builtins.concatStringsSep " " [
    # include libcxx headers
    "-cxx-isystem${libcxx-dev}/include"

    # CFLAGS _must_ go after C++ includes
    cflagsSgx
  ];
in

stdenv.mkDerivation (final: {
  pname = "x86_64-fortanix-unknown-sgx-rust-std";
  version = "1.90.0";

  src = fetchFromGitHub {
    owner = "phlip9";
    repo = "rust";
    rev = "lexe-1.90.0-2025_12_07";
    fetchSubmodules = true;
    hash = "sha256-eSngC2xtyCet70DaKtCjLZf7znbQlaH42VPYE3d2mP4=";
  };

  cargoVendorDir = callPackage ./rust-std-vendor.nix {
    inherit rustc cargo;
    name = "rust-std-vendor-${final.version}";
    vendorSrc = final.src;
    hash = "sha256-Jw/wXp5nPdieDqHKQeqAe3Z3GFb8UVYP1i8KAAyLs7U=";
  };

  __darwinAllowLocalNetworking = true;

  nativeBuildInputs = [
    cmake
    file
    ninja
    python3
    rustc
    which
  ];

  postPatch = ''
    patchShebangs src/etc

    # fake some submodules
    mkdir -p \
      src/gcc \
      src/tools/cargo \
      src/tools/rustc-perf \
      src/tools/enzyme/enzyme

    # Wire up vendored crates.io crates
    ln -s $cargoVendorDir vendor
    mkdir -p .cargo
    cat >> .cargo/config.toml <<\EOF
    [source.crates-io]
    replace-with = "vendored-sources"
    [source.vendored-sources]
    directory = "vendor"
    EOF
  '';

  # rustc complains about modified source files otherwise
  dontUpdateAutotoolsGnuConfigScripts = true;

  # rustc unfortunately needs cmake to compile llvm-rt but doesn't
  # use it for the normal build. This disables cmake in Nix.
  dontUseCmakeConfigure = true;

  configurePlatforms = [ ];

  enableParallelBuilding = true;

  # LZMA_API_STATIC=1 : Just build lzma-sys crate from xz source to reduce
  #                     linker headaches.
  preConfigure = ''
    export \
      CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-Clinker-features=-lld -Clink-self-contained=-linker" \
      CARGO_TARGET_X86_64_FORTANIX_UNKNOWN_SGX_RUSTFLAGS="${rustflagsSgx}" \
      CFLAGS_x86_64_fortanix_unknown_sgx="${cflagsSgx}" \
      CXXFLAGS_x86_64_fortanix_unknown_sgx="${cxxflagsSgx}" \
      LZMA_API_STATIC=1
  '';

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

      setBuild = "--set=target.\"${stdenv.buildPlatform.rust.rustcTarget}\"";
      setHost = "--set=target.\"${stdenv.hostPlatform.rust.rustcTarget}\"";
      setTarget = "--set=target.\"${target}\"";
    in
    [
      "--build=${buildPlatform.rust.rustcTargetSpec}"
      "--host=${hostPlatform.rust.rustcTargetSpec}"
      "--target=${target}"

      "--disable-llvm-bitcode-linker"
      "--enable-llvm-link-shared"
      "--enable-local-rebuild"
      "--enable-local-rust"
      "--enable-locked-deps"
      "--enable-option-checking"
      "--enable-vendor"
      "--release-channel=stable"
      "--set=build.cargo=${cargo}/bin/cargo"
      "--set=build.rustc=${rustc}/bin/rustc"
      "--set=change-id=ignore"
      "--sysconfdir=${placeholder "out"}/etc"
      "--tools="

      "${setBuild}.cc=${ccForBuild}"
      "${setBuild}.cxx=${cxxForBuild}"
      "${setBuild}.linker=${ccForBuild}"
      "${setBuild}.crt-static=${lib.boolToString stdenv.buildPlatform.isStatic}"
      "${setBuild}.llvm-config=${llvmSharedForBuild.dev}/bin/llvm-config"

      "${setHost}.cc=${ccForHost}"
      "${setHost}.cxx=${cxxForHost}"
      "${setHost}.linker=${ccForHost}"
      "${setHost}.crt-static=${lib.boolToString stdenv.hostPlatform.isStatic}"
      "${setHost}.llvm-config=${llvmSharedForHost.dev}/bin/llvm-config"

      "${setTarget}.ar=${lib.getExe' bintools-unwrapped "ar"}"
      "${setTarget}.cc=${lib.getExe' clang-unwrapped "clang"}"
      "${setTarget}.crt-static=true"
      "${setTarget}.cxx=${lib.getExe' clang-unwrapped "clang++"}"
      "${setTarget}.linker=${lib.getExe' lld "ld.lld"}"
      "${setTarget}.llvm-config=${llvmSharedForHost.dev}/bin/llvm-config"
      "${setTarget}.ranlib=${lib.getExe' bintools-unwrapped "ar"}"
    ];

  buildPhase = ''
    runHook preBuild

    # coerce bootstrap into using our existing rustc
    mkdir -p build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage{0,1}-{std,rustc}/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/
    ln -s ${rustc.unwrapped}/lib/rustlib/${stdenv.hostPlatform.rust.rustcTargetSpec}/libstd-*.so build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-std/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/libstd.so
    ln -s ${rustc.unwrapped}/lib/rustlib/${stdenv.hostPlatform.rust.rustcTargetSpec}/librustc_driver-*.so build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/librustc.so
    ln -s ${rustc.unwrapped}/bin/rustc build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/rustc-main
    ln -s ${rustc.unwrapped}/bin/rustc build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage1-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/rustc-main
    touch build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage0-std/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/.libstd-stamp
    touch build/${stdenv.hostPlatform.rust.rustcTargetSpec}/stage{0,1}-rustc/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/.librustc-stamp

    # build rust-std for x86_64-fortanix-unknown-sgx
    python ./x.py --keep-stage=0 --stage=1 build library # --verbose

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # install into ./inst/
    python ./x.py --keep-stage=0 --stage=1 install library/std # --verbose

    runHook postInstall
  '';

  postInstall = ''
    # remove stuff that doesn't make sense for a rust-std only nix package
    rmdir $out/etc
    rm $out/lib/rustlib/install.log $out/lib/rustlib/uninstall.sh \
       $out/lib/rustlib/rust-installer-version $out/lib/rustlib/components \
       $out/lib/rustlib/manifest-rust-std-x86_64-fortanix-unknown-sgx
  '';

  outputs = [ "out" ];
  setOutputFlags = false;

  # let the rust build system handle stripping
  dontStrip = true;

  # the rust build system complains that nix alters the checksums
  dontFixLibtool = true;

  passthru = {
    inherit libcxx-dev;
  };
})
