{
  lib,
  pkgs,
  pkgsUnfree,
  ...
}: let
  # composeAndroidPackages =
  # { cmdLineToolsVersion ? "13.0"
  # , toolsVersion ? "26.1.1"
  # , platformToolsVersion ? "35.0.1"
  # , buildToolsVersions ? [ "34.0.0" ]
  # , includeEmulator ? false
  # , emulatorVersion ? "35.1.4"
  # , platformVersions ? []
  # , includeSources ? false
  # , includeSystemImages ? false
  # , systemImageTypes ? [ "google_apis" "google_apis_playstore" ]
  # , abiVersions ? [ "x86" "x86_64" "armeabi-v7a" "arm64-v8a" ]
  # , cmakeVersions ? [ ]
  # , includeNDK ? false
  # , ndkVersion ? "26.3.11579264"
  # , ndkVersions ? [ndkVersion]
  # , useGoogleAPIs ? false
  # , useGoogleTVAddOns ? false
  # , includeExtras ? []
  # , repoJson ? ./repo.json
  # , repoXmls ? null
  # , extraLicenses ? []
  # }:
  androidSdkComposition = pkgsUnfree.androidenv.composeAndroidPackages rec {
    abiVersions = ["armeabi-v7a" "arm64-v8a"];
    platformVersions = [
      "34" # lexe
      "31" # app_links
    ];
    buildToolsVersions = [
      "30.0.3" # gradle android plugin seems to want this?
    ];
    includeNDK = true;
    ndkVersion = "26.3.11579264";
    ndkVersions = [
      ndkVersion # lexe
      "23.1.7779620" # flutter_zxing
    ];
    cmakeVersions = ["3.18.1"]; # flutter_zxing
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
  flutter = pkgs.flutter324;

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
    ]);

  programs.bash.initExtra = ''
    export ANDROID_HOME=${ANDROID_HOME}
    export ANDROID_NDK_ROOT=${ANDROID_NDK_ROOT}
    export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT}
    export FLUTTER_ROOT=${flutter}
    export JAVA_HOME=${JAVA_HOME}
  '';
}
