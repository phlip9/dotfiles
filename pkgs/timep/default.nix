# timep - efficient per-command profiling for bash scripts
#
# Usage:
# - timep -s path/to/script
# - timep -c -- command ...
{
  bash,
  coreutils,
  fetchFromGitHub,
  findutils,
  gnugrep,
  gnused,
  lib,
  perl,
  runCommand,
  stdenv,
  util-linux,
}:

stdenv.mkDerivation (final: {
  pname = "timep";
  version = "1.10.1";

  src = fetchFromGitHub {
    owner = "jkool702";
    repo = "timep";
    tag = "v${final.version}";
    hash = "sha256-kHH4tphVYjUcYObK2fHBmaRKsggV9IOMaopCYsLqag0=";
    # repo is huge, so use a sparse checkout
    sparseCheckout = [
      "LIB/LOADABLES/SRC/timep.c"
      "LIB/timep_flamegraph.pl"
      "timep.bash"
    ];
  };

  strictDeps = true;
  buildInputs = [
    bash
    bash.dev
    coreutils
    findutils
    gnugrep
    gnused
    perl
  ];

  postPatch = ''
    # nix bash supports standard loadable builtins via *_struct symbols.
    # add_builtin() is not exported, so drop upstream's manual registration.
    substituteInPlace LIB/LOADABLES/SRC/timep.c \
      --replace-fail 'extern int add_builtin(struct builtin *bp, int keep);' "" \
      --replace-fail $'int setup_builtin_timep(void) {\n    add_builtin(&getCPUtime_struct, 1);\n    add_builtin(&timep_fnv1a_struct, 1);\n    add_builtin(&timep_crc32_struct, 1);\n    add_builtin(&timep_hash_struct, 1);\n\n    return EXECUTION_SUCCESS;\n}' ""

    # use an awk script to patch out embedded base64-encoded timep.so extract
    awk -i inplace -f ${./fixup-timep-bash.awk} \
      -v timepSo="$out/lib/timep.so" \
      -v timepFlamegraphPl="$out/share/timep/timep_flamegraph.pl" \
      timep.bash

    # need to manually patchShebangs some of these embedded scripts
    substituteInPlace timep.bash \
      --replace-fail '#!/usr/bin/env bash' "#!$(PATH="$HOST_PATH" type -P bash)"
  '';

  buildPhase = ''
    runHook preBuild

    # build timep.so native bash extensions
    $CC -Wall -fPIC -flto -O3 \
      ${lib.optionalString stdenv.hostPlatform.isx86_64 "-msse4.2"} \
      ${lib.optionalString stdenv.hostPlatform.isAarch64 "-march=armv8-a+crc"} \
      -DSHELL \
      -DLOADABLE_BUILTIN \
      -DHAVE_CONFIG_H \
      -DSELECT_COMMAND \
      -I${bash.dev}/include/bash \
      -I${bash.dev}/include/bash/builtins \
      -I${bash.dev}/include/bash/include \
      -shared \
      -o timep.so \
      LIB/LOADABLES/SRC/timep.c

    # add convenient wrapper bin
    cat > timep <<'EOF'
      #!@bash@
      export PATH="''${PATH:+$PATH:}@HOST_PATH@"
      source "@out@/share/timep/timep.bash"
      timep "$@"
    EOF
    substituteInPlace timep \
      --replace-fail '@bash@' "$(PATH="$HOST_PATH" type -P bash)" \
      --replace-fail '@HOST_PATH@' "$HOST_PATH" \
      --replace-fail '@out@' "$out"
    chmod 755 timep

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m755 timep $out/bin/timep
    install -D -m755 timep.so $out/lib/timep.so
    install -D -m755 timep.bash $out/share/timep/timep.bash
    install -D -m755 LIB/timep_flamegraph.pl $out/share/timep/timep_flamegraph.pl
    runHook postInstall
  '';

  passthru.tests.test =
    runCommand "${final.pname}-test"
      {
        nativeBuildInputs = [
          bash
          final.finalPackage
          util-linux
        ];
        meta.platforms = final.meta.platforms;
      }
      ''
        # can't use `/dev/shm` in sandbox. timep also tries to escape one level
        # down from $TIMEP_TMPDIR, so shove it one layer deeper...
        tmpdir="$(mktemp -d)"
        mkdir -p "$tmpdir/timep"
        export TIMEP_TMPDIR="$tmpdir/timep"
        pushd "$TIMEP_TMPDIR"

        # check bash can load builtins
        enable -f "${final.finalPackage}/lib/timep.so" \
          getCPUtime timep_crc32 timep_fnv1a timep_hash
        getCPUtime >/dev/null
        timep_hash <<<"timep-self-test" >/dev/null

        # check profiling
        cat > timep-script.bash <<EOF
          #!$(type -P bash)
          true
        EOF
        chmod 755 timep-script.bash
        script -qefc 'timep -s -- timep-script.bash >/dev/null' /dev/null

        # check profiling output
        if [[ ! -f timep.profiles/out.profile ]]; then
          echo 2>&1 "error: timep profiling didn't produce out.profile output"
          ls -la timep.profiles/
          exit 1
        fi
        if [[ ! -f timep.profiles/out.flamegraph ]]; then
          echo 2>&1 "error: timep profiling didn't produce out.flamegraph output"
          ls -la timep.profiles/
          exit 1
        fi

        popd
        touch $out
      '';

  meta = {
    mainProgram = "timep";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
