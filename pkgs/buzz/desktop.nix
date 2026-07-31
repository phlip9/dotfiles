{
  lib,
  stdenv,
  fetchurl,
  linkFarm,
  rust,
  rustPlatform,

  cmake,
  pkg-config,

  alsa-lib,
  glib-networking,
  gtk3,
  libayatana-appindicator,
  libopus,
  librsvg,
  openssl,
  webkitgtk_4_1,
  xdotool,

  frontend,
  sidecarNames,
  src,
  version,
}:

let
  targetTriple = rust.envVars.rustHostPlatformSpec;

  # sherpa-onnx-sys otherwise downloads its native archive during the build.
  sherpaOnnxVersion = "1.13.4";
  sherpaOnnxArchive =
    {
      aarch64-darwin = {
        suffix = "osx-arm64-static-lib";
        hash = "sha256-V4Adsru3hqXTQ/UVo4/yELQBhCM4vcgE+gdTEtHNJAQ=";
      };
      x86_64-linux = {
        suffix = "linux-x64-static-lib";
        hash = "sha256-mLDjGZZCb254JE284ZVVSPLGTo8BxL51uFr3zaoujVw=";
      };
    }
    .${stdenv.hostPlatform.system}
      or (throw "buzz: unsupported platform ${stdenv.hostPlatform.system}");
  sherpaOnnxArchiveName = lib.concatStrings [
    "sherpa-onnx-v${sherpaOnnxVersion}-"
    sherpaOnnxArchive.suffix
    ".tar.bz2"
  ];
  sherpaOnnxArchiveFile = fetchurl {
    name = sherpaOnnxArchiveName;
    url =
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
      + "v${sherpaOnnxVersion}/${sherpaOnnxArchiveName}";
    inherit (sherpaOnnxArchive) hash;
  };
  sherpaOnnxArchiveDir = linkFarm "buzz-sherpa-onnx-archive" [
    {
      name = sherpaOnnxArchiveName;
      path = sherpaOnnxArchiveFile;
    }
  ];
in

rustPlatform.buildRustPackage {
  pname = "buzz-desktop";
  inherit src version;

  cargoRoot = "desktop/src-tauri";
  buildAndTestSubdir = "desktop/src-tauri";
  cargoHash = "sha256-2SWtMPUxuW6hV9mExBHkNe6Qw1aKUB40Jbax5mgvA0U=";

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  buildInputs =
    lib.optionals stdenv.hostPlatform.isLinux [
      alsa-lib
      glib-networking
      gtk3
      libayatana-appindicator
      libopus
      librsvg
      openssl
      webkitgtk_4_1
      xdotool
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ libopus ];

  env = {
    CMAKE_POLICY_VERSION_MINIMUM = "3.5";
    OPENSSL_NO_VENDOR = 1;
    SHERPA_ONNX_ARCHIVE_DIR = sherpaOnnxArchiveDir;
  };

  # sherpa-onnx-sys selects its native archive using its Cargo package
  # version. Keep the explicit archive pin honest when Cargo.lock changes.
  postPatch = ''
    sherpaOnnxLockVersion="$(
      sed -n '
        /^name = "sherpa-onnx-sys"$/ {
          n
          s/^version = "\(.*\)"$/\1/p
          q
        }
      ' desktop/src-tauri/Cargo.lock
    )"

    if [ "$sherpaOnnxLockVersion" != "${sherpaOnnxVersion}" ]; then
      echo \
        "buzz: Sherpa ONNX archive ${sherpaOnnxVersion} does not match" \
        "sherpa-onnx-sys $sherpaOnnxLockVersion in Cargo.lock" \
        >&2
      exit 1
    fi
  '';

  # Tauri embeds the frontend while compiling its generated context. Its build
  # script only validates and copies the sidecars, so placeholders keep sidecar
  # changes from rebuilding this expensive derivation. The final bundle stages
  # the real binaries.
  preBuild = ''
    mkdir -p desktop/dist desktop/src-tauri/binaries
    cp -R "${frontend}/." desktop/dist/

    for sidecar in ${lib.escapeShellArgs sidecarNames}; do
      install -Dm755 \
        /dev/null \
        "desktop/src-tauri/binaries/$sidecar-${targetTriple}"
    done
  '';

  # Tests assume FHS shell paths, system CA certificates, and ambient tools.
  doCheck = false;

  installPhase = ''
    runHook preInstall

    install -Dm755 \
      "target/${targetTriple}/release/buzz-desktop" \
      "$out/bin/buzz-desktop"

    runHook postInstall
  '';
}
