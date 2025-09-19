{
  lib,
  pkgs,
  pkgsUnfree,
  pkgsYubikey,
  ...
}: let
  # composeAndroidPackages =
  # { cmdLineToolsVersion ? "latest",
  # , toolsVersion ? "latest",
  # , platformToolsVersion ? "latest",
  # , buildToolsVersions ? [ "latest" ],
  # , includeEmulator ? false,
  # , emulatorVersion ? "latest",
  # , minPlatformVersion ? null,
  # , maxPlatformVersion ? "latest",
  # , numLatestPlatformVersions ? 1,
  # , platformVersions ? ..,
  # , includeSources ? false,
  # , includeSystemImages ? false,
  # , systemImageTypes ? [ "google_apis" "google_apis_playstore" ],
  # , abiVersions ? [ "x86" "x86_64" "armeabi-v7a" "arm64-v8a" ],
  # , includeCmake ? stdenv.hostPlatform.isx86_64 || stdenv.hostPlatform.isDarwin,
  # , cmakeVersions ? [ "latest" ],
  # , includeNDK ? false,
  # , ndkVersion ? "latest",
  # , ndkVersions ? [ ndkVersion ],
  # , useGoogleAPIs ? false,
  # , useGoogleTVAddOns ? false,
  # , includeExtras ? [ ],
  # , repoJson ? ./repo.json,
  # , repoXmls ? null,
  # , extraLicenses ? [ ],
  # }:
  androidSdkComposition = pkgsUnfree.androidenv.composeAndroidPackages rec {
    abiVersions = ["armeabi-v7a" "arm64-v8a"];
    platformVersions = [
      "35" # lexe
      "34" # app_links, flutter_zxing -> camera_android_camerax
    ];
    buildToolsVersions = [
      "34.0.0" # gradle android plugin seems to want this?
    ];
    includeNDK = true;
    ndkVersion = "27.0.12077973";
    ndkVersions = [
      ndkVersion # lexe, flutter_zxing
    ];
    cmakeVersions = ["3.22.1"]; # flutter_zxing
  };

  # Links all the toolchains/libs/bins/etc in our chosen `androidSdkComposition`
  # into a single derivation.
  androidSdk = androidSdkComposition.androidsdk;

  # Android envs
  ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
  ANDROID_HOME = ANDROID_SDK_ROOT;
  ANDROID_NDK_ROOT = "${ANDROID_SDK_ROOT}/ndk/${androidSdkComposition.ndk-bundle.version}";
  JAVA_HOME = "${pkgs.jdk17_headless.home}";

  # flutter/dart
  flutter = pkgs.flutter332;

  isDarwin = pkgs.hostPlatform.isDarwin;
in {
  home.packages =
    [
      flutter
      pkgs.bundletool
      pkgs.cargo-expand
      pkgs.cargo-ndk
      pkgs.fastlane
      pkgs.josh
      pkgs.lego
      pkgs.rage
      pkgs.toml-cli
      pkgsYubikey.age-plugin-yubikey
    ]
    ++ (lib.optionals isDarwin [
      pkgs.cocoapods

      # provides idevicesyslog to follow attached iOS device logs from CLI
      pkgs.libimobiledevice

      # Use standard rsync by default. macOS rsync (OpenBSD-based) doesn't copy
      # Flutter.framework with the right permissions. However xcodebuild calls
      # rsync with some magic apple flags, so we need to use apple rsync for
      # those cases.
      (pkgs.writeShellScriptBin "rsync" ''
        # Use apple rsync if we get the special magic apple only
        # --extended-attributes flag.
        for arg in "$@"; do
          if [[ "$arg" == "--extended-attributes" ]]; then
            exec /usr/bin/rsync "$@"
          fi
        done

        exec ${pkgs.rsync}/bin/rsync "$@"
      '')
    ]);

  programs.bash.initExtra = ''
    export ANDROID_HOME=${ANDROID_HOME}
    export ANDROID_NDK_ROOT=${ANDROID_NDK_ROOT}
    export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT}
    export FLUTTER_ROOT=${flutter}
    export JAVA_HOME=${JAVA_HOME}
  '';
}
