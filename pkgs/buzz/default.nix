{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  fetchurl,
  linkFarm,
  makeBinaryWrapper,
  rust,
  rustPlatform,

  cargo-tauri,
  cmake,
  nodejs,
  pkg-config,
  pnpm_11,
  pnpmConfigHook,
  wrapGAppsHook4,

  alsa-lib,
  glib-networking,
  gtk3,
  libayatana-appindicator,
  libopus,
  librsvg,
  openssl,
  webkitgtk_4_1,
  xdotool,
}:

let
  pnpm = pnpm_11;

  sidecarNames = [
    "buzz-acp"
    "buzz-agent"
    "buzz-dev-mcp"
    "git-credential-nostr"
    "buzz"
  ];

  # sherpa-onnx-sys downloads this archive from its build script by default.
  # Stage the exact upstream binary release for sandboxed, reproducible builds.
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
  sherpaOnnxArchiveName =
    "sherpa-onnx-v${sherpaOnnxVersion}-" + "${sherpaOnnxArchive.suffix}.tar.bz2";
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

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "buzz";
  version = "0.5.2";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    tag = "v${finalAttrs.version}";
    hash = "sha256-VWqoIS5FMyou6fEuuUq1OUIPycAtn0kVLbm5yCQAsOs=";
  };

  cargoRoot = "desktop/src-tauri";
  buildAndTestSubdir = finalAttrs.cargoRoot;
  cargoHash = "sha256-2SWtMPUxuW6hV9mExBHkNe6Qw1aKUB40Jbax5mgvA0U=";

  # Tests assume FHS shell paths, system CA certificates, and ambient tools.
  doCheck = false;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-Tboy+MG/VvdxUpJw7Xv0oubK58MIpvChvbU30uO4M4A=";
  };

  nativeBuildInputs = [
    cargo-tauri.hook
    cmake
    nodejs
    pkg-config
    pnpm
    pnpmConfigHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ wrapGAppsHook4 ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ makeBinaryWrapper ];

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
    COREPACK_ENABLE_STRICT = 0;
    OPENSSL_NO_VENDOR = 1;
    SHERPA_ONNX_ARCHIVE_DIR = sherpaOnnxArchiveDir;
  };

  # Tauri validates and bundles target-qualified sidecars during its build.
  preBuild = ''
    mkdir -p desktop/src-tauri/binaries
    for sidecar in ${lib.escapeShellArgs sidecarNames}; do
      cp \
        "${finalAttrs.passthru.sidecars}/bin/$sidecar" \
        "desktop/src-tauri/binaries/$sidecar-${rust.envVars.rustHostPlatformSpec}"
    done
  '';

  postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
    makeBinaryWrapper \
      "$out/Applications/Buzz.app/Contents/MacOS/buzz-desktop" \
      "$out/bin/buzz-desktop"
  '';

  passthru.sidecars = rustPlatform.buildRustPackage {
    pname = "buzz-sidecars";
    inherit (finalAttrs) version src;

    cargoHash = "sha256-0a0SJqDjSTWXU6k3yZ6iisDaUdnHqzjZU33ItzGs8AY=";
    cargoBuildFlags = [
      "-p"
      "buzz-acp"
      "-p"
      "buzz-agent"
      "-p"
      "buzz-dev-mcp"
      "-p"
      "git-credential-nostr"
      "-p"
      "buzz-cli"
    ];

    # This internal derivation only supplies release binaries to Tauri. The
    # top-level workspace test suite is outside that build's scope.
    doCheck = false;

    postInstall = ''
      rm -f "$out/bin/fake-mcp"
    '';
  };

  meta = {
    description = "Workspace where humans and agents build together";
    homepage = "https://github.com/block/buzz";
    changelog = "https://github.com/block/buzz/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    mainProgram = "buzz-desktop";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
})
