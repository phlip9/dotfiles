{
  lib,
  pkgs,
  pkgsUnfree,
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
      pkgs.age-plugin-yubikey
      pkgs.bundletool
      pkgs.cargo-expand
      pkgs.cargo-ndk
      pkgs.fastlane
      pkgs.josh
      pkgs.rage
      pkgs.toml-cli
    ]
    ++ (lib.optionals isDarwin [
      pkgs.cocoapods
      # provides idevicesyslog to follow attached iOS device logs from CLI
      pkgs.libimobiledevice
      # Use standard rsync. macOS rsync (OpenBSD) doesn't copy Flutter.framework
      # with the right permissions.
      pkgs.rsync
    ]);

  programs.bash.initExtra = ''
    export ANDROID_HOME=${ANDROID_HOME}
    export ANDROID_NDK_ROOT=${ANDROID_NDK_ROOT}
    export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT}
    export FLUTTER_ROOT=${flutter}
    export JAVA_HOME=${JAVA_HOME}
  '';
}
