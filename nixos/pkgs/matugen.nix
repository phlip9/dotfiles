# A cross-platform material you and base16 color generation tool
#
# See: pkgs/matugen-themes.nix
{
  fetchFromGitHub,
  matugen-themes,
  nix-update-script,
  runCommand,
  rustPlatform,
}:

let
  matugen = rustPlatform.buildRustPackage (finalAttrs: {
    pname = "matugen";
    version = "4.2.0";

    src = fetchFromGitHub {
      owner = "InioX";
      repo = "matugen";
      tag = "v${finalAttrs.version}";
      hash = "sha256-VbzUY/0Q44vNYa+HB5qpctSpVsnPB+aYsFsx77Ggc7I=";
    };

    cargoHash = "sha256-jmeyg1HWlRL8bdMhjqUVcd9TR6XtwP5aRGJAx4FYshw=";

    cargoBuildFlags = "-p matugen --bin matugen";

    meta = {
      mainProgram = "matugen";
    };

    passthru = {
      updateScript = nix-update-script { };

      # matugen color templates
      templates = matugen-themes;

      # Generate color themes from an image.
      mkConfigs =
        {
          name,
          image,
          mode,
          contrast,
          type,
          sourceColorIndex,
        }:
        runCommand name
          {
            nativeBuildInputs = [ matugen ];
            inherit (finalAttrs.passthru) templates;
          }
          # See available templates: <https://github.com/InioX/matugen-themes>
          ''
            mkdir -p $out

            cat <<EOF | tee config.toml
            [config]

            # [templates.alacritty]
            # input_path = "$templates/alacritty.toml"
            # output_path = "$out/config/alacritty/colors/$name.toml"

            [templates.fuzzel]
            input_path = "$templates/fuzzel.ini"
            output_path = "$out/config/fuzzel/colors/$name.ini"

            [templates.gtk3]
            input_path = "$templates/gtk-colors.css"
            output_path = "$out/config/gtk-3.0/colors/$name.css"

            [templates.gtk4]
            input_path = "$templates/gtk-colors.css"
            output_path = "$out/config/gtk-4.0/colors/$name.css"

            [templates.niri]
            input_path = "$templates/niri-colors.kdl"
            output_path = "$out/config/niri/colors/$name.kdl"

            [templates.qt5ct]
            input_path = "$templates/qtct-colors.conf"
            output_path = "$out/config/qt5ct/colors/$name.conf"

            [templates.qt6ct]
            input_path = "$templates/qtct-colors.conf"
            output_path = "$out/config/qt6ct/colors/$name.conf"

            [templates.tmux]
            input_path = "$templates/tmux-colors.conf"
            output_path = "$out/config/tmux/colors/$name.conf"
            EOF

            matugen image ${image} \
              --mode ${mode} \
              --type ${type} \
              --contrast ${contrast} \
              --source-color-index ${sourceColorIndex} \
              --config ./config.toml
          '';
    };
  });

in
matugen
