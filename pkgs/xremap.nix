# TODO(phlip9): remove once we upgrade to release-25.11
{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage rec {
  pname = "xremap";
  version = "0.14.2";

  src = fetchFromGitHub {
    owner = "xremap";
    repo = pname;
    tag = "v${version}";
    hash = "sha256-5BHet5kKpmJFpjga7QZoLPydtzs5iPX5glxP4YvsYx0=";
  };

  cargoHash = "sha256-NZNLO+wmzEdIZPp5Zu81m/ux8Au+8EMq31QpuZN9l5w=";

  nativeBuildInputs = [ ];

  buildNoDefaultFeatures = true;
  buildFeatures = [ ];

  meta = {
    description = "Key remapper for X11 and Wayland";
    homepage = "https://github.com/xremap/xremap";
    license = lib.licenses.mit;
    mainProgram = "xremap";
    platforms = lib.platforms.linux;
  };
}
