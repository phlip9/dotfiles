{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  makeBinaryWrapper,
  nix-update-script,
  rust,
  rustPlatform,

  cargo-tauri,
  pnpm_11,
  wrapGAppsHook4,

  alsa-lib,
  glib-networking,
  gst_all_1,
  gtk3,
  libayatana-appindicator,
  libopus,
  librsvg,
  openssl,
  webkitgtk_4_1,
  xdotool,
}:

let
  version = "0.5.2";
  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    tag = "v${version}";
    hash = "sha256-VWqoIS5FMyou6fEuuUq1OUIPycAtn0kVLbm5yCQAsOs=";
  };

  pnpm = pnpm_11;
  targetTriple = rust.envVars.rustHostPlatformSpec;
  sidecarNames = [
    "buzz-acp"
    "buzz-agent"
    "buzz-dev-mcp"
    "git-credential-nostr"
    "buzz"
  ];

  frontend = callPackage ./frontend.nix {
    inherit
      pnpm
      src
      version
      ;
  };
  sidecars = callPackage ./sidecars.nix { inherit src version; };
  desktop = callPackage ./desktop.nix {
    inherit
      frontend
      sidecarNames
      src
      version
      ;
  };
in

stdenv.mkDerivation (finalAttrs: {
  pname = "buzz";
  inherit src version;

  # cargo-tauri bundle still reads Cargo metadata, but reuses the independently
  # compiled desktop executable instead of invoking Cargo's build command.
  cargoRoot = "desktop/src-tauri";
  cargoDeps = desktop.cargoDeps;
  cargoBuildType = "release";
  tauriBundleType = if stdenv.hostPlatform.isLinux then "deb" else "app";

  nativeBuildInputs = [
    cargo-tauri.hook
    rustPlatform.cargoSetupHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ wrapGAppsHook4 ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ makeBinaryWrapper ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    alsa-lib
    glib-networking

    # WebKit aborts if its GStreamer media elements are missing at runtime.
    gst_all_1.gst-libav
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gstreamer
    gtk3
    libayatana-appindicator
    libopus
    librsvg
    openssl
    webkitgtk_4_1
    xdotool
  ];

  buildPhase = ''
    runHook preBuild

    export CARGO_TARGET_DIR="$PWD/target"
    targetDir="$CARGO_TARGET_DIR/${targetTriple}/release"

    mkdir -p \
      "$targetDir" \
      desktop/dist \
      desktop/src-tauri/binaries
    install -m755 \
      "${desktop}/bin/buzz-desktop" \
      "$targetDir/buzz-desktop"
    cp -R "${frontend}/." desktop/dist/

    for sidecar in ${lib.escapeShellArgs sidecarNames}; do
      install -m755 \
        "${sidecars}/bin/$sidecar" \
        "desktop/src-tauri/binaries/$sidecar-${targetTriple}"
    done

    pushd desktop/src-tauri
    cargo tauri bundle \
      --bundles "$tauriBundleType" \
      --ci \
      --no-sign \
      --target ${targetTriple}
    popd

    runHook postBuild
  '';

  postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
    mkdir -p "$out/bin"
    makeBinaryWrapper \
      "$out/Applications/Buzz.app/Contents/MacOS/buzz-desktop" \
      "$out/bin/buzz-desktop"
  '';

  # Keep CLI sidecars unwrapped so Tauri can execute their adjacent binaries.
  dontWrapGApps = true;
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    wrapGApp "$out/bin/buzz-desktop"
  '';

  passthru = {
    inherit desktop frontend sidecars;
    tests = lib.optionalAttrs stdenv.hostPlatform.isLinux {
      headless = callPackage ./headless-test.nix {
        buzz = finalAttrs.finalPackage;
      };
    };
    updateScript = nix-update-script {
      extraArgs = [
        "--subpackage"
        "frontend"
        "--subpackage"
        "sidecars"
        "--subpackage"
        "desktop"
      ];
    };
  };

  meta = {
    description = "Workspace where humans and agents build together";
    homepage = "https://github.com/block/buzz";
    changelog = "https://github.com/block/buzz/releases/tag/v${version}";
    license = lib.licenses.asl20;
    mainProgram = "buzz-desktop";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };
})
