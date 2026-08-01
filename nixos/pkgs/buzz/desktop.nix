{
  lib,
  stdenv,
  fetchurl,
  linkFarm,
  rust,
  rustPlatform,

  cacert,
  cmake,
  gitMinimal,
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

  # These tests create FHS scripts, spawn fixed FHS paths, or clear PATH before
  # spawning an ambient tool. Nix's Linux sandbox only provides /bin/sh.
  linuxFhsTestSkips = [
    "commands::agent_auth::tests::auth_command_uses_augmented_path_for_node_adapter"
    "commands::agent_discovery::tests::test_composed_path_survives_a_profile_that_clears_it"
    "commands::agent_discovery::tests::test_install_shell_pipeline_status_follows_left_side"
    "managed_agents::agent_env::tests::baked_defaults_do_not_override_record_provider_written_after"
    "managed_agents::agent_env::tests::buzz_agent_provider_defaults_empty_in_oss_build"
    "managed_agents::discovery::tests::codex_version::probe_codex_acp_version_uses_augmented_path_for_env_shebang_interpreter"
    "managed_agents::readiness::cli_probe::tests::login_probe_uses_augmented_path_for_env_shebang_interpreter"
    "managed_agents::runtime::tests::grandchild_inherits_pgid_of_process_group_leader"
    "managed_agents::runtime::tests::kill_stale_live_pair_is_not_touched"
    "managed_agents::runtime::tests::own_group_grandchild_detected_by_ancestor_walk"
  ];

  # This test leaves a 300-second process-global admission gate armed, which
  # races with the parallel relay admission tests.
  sharedStateTestSkips = [
    "relay::tests::oversized_hint_is_capped_in_relay_error_message_string"
  ];

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
  cargoCheckType = "release";

  # Tauri's CLI enables this for production builds. Without it, the prebuilt
  # executable loads build.devUrl instead of serving the embedded frontend.
  cargoBuildFlags = [ "--features=tauri/custom-protocol" ];

  # cargo test replaces the top-level executable, so use the production
  # feature there too rather than installing a development build afterward.
  cargoTestFlags = [ "--features=tauri/custom-protocol" ];

  # Upstream's release-profile tests reference helpers gated on
  # debug_assertions. Include those helpers whenever the test harness is built.
  patches = [ ./release-profile-tests.patch ];

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  # Tests construct HTTPS clients and invoke Git inside the Nix sandbox.
  nativeCheckInputs = [
    cacert
    gitMinimal
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

  preCheck = ''
    export HOME="$NIX_BUILD_TOP/test-home"
    mkdir -p "$HOME"
  '';

  checkFlags = map (test: "--skip=${test}") (
    sharedStateTestSkips
    ++ lib.optionals stdenv.hostPlatform.isLinux linuxFhsTestSkips
  );

  installPhase = ''
    runHook preInstall

    install -Dm755 \
      "target/${targetTriple}/release/buzz-desktop" \
      "$out/bin/buzz-desktop"

    runHook postInstall
  '';
}
