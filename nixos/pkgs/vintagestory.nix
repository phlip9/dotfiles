{
  vintagestory,
  fetchurl,
  dotnet-runtime_10,
}:

let
  vintagestoryWayland = vintagestory.override {
    # # Use Wayland
    # # NOTE(phlip9): disabled wayland. appears to work fine, but this spooky
    # # log gets spammed like once per frame lol...
    # # 19.4.2026 10:05:51 [Error] GLFW Exception: ErrorCode:FeatureUnavailable Wayland: The platform does not provide the window position
    # x11Support = false;
    # waylandSupport = true;

    # unstable needs a newer dotnet
    dotnet-runtime_8 = dotnet-runtime_10;
  };

in

vintagestoryWayland.overrideAttrs (
  final: prev: {
    version = "1.22.0-rc.10";
    src = fetchurl {
      url = "https://cdn.vintagestory.at/gamefiles/unstable/vs_client_linux-x64_${final.version}.tar.gz";
      hash = "sha256-4kxKC99uBUHhkH/Nm5zBezhCasKUpdG/q/cgXZ3G1Ro=";
    };

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/vintagestory $out/bin $out/share/icons/hicolor/512x512/apps $out/share/fonts/truetype
      cp -r * $out/share/vintagestory
      # magick $out/share/vintagestory/assets/gameicon.xpm $out/share/icons/hicolor/512x512/apps/vintagestory.png
      ln $out/share/vintagestory/assets/gameicon.png $out/share/icons/hicolor/512x512/apps/vintagestory.png
      ln $out/share/vintagestory/assets/game/fonts/*.ttf $out/share/fonts/truetype

      runHook postInstall
    '';
  }
)
