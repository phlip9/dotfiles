{
  fetchFromGitHub,
  rustPlatform,
  runCommand,
}:

let
  matugen = rustPlatform.buildRustPackage (finalAttrs: {
    pname = "matugen";
    version = "4.0.0";

    src = fetchFromGitHub {
      owner = "InioX";
      repo = "matugen";
      tag = "v${finalAttrs.version}";
      hash = "sha256-2jcqAU8QutF8AE15LYwd8cy7KjayGxUGHxvWnqAiS5M=";
    };

    cargoHash = "sha256-RlzY0eaYrEVkO7ozzgfLHxKB2jy4nSYda9Z0jrqiUVA=";

    cargoBuildFlags = "-p matugen --bin matugen";

    meta = {
      mainProgram = "matugen";
    };

    passthru = {
      # matugen-provided templates
      templates = fetchFromGitHub {
        owner = "InioX";
        repo = "matugen-themes";
        rev = "dd6fd47ad87d82172da2339da3e985136502fb3b";
        hash = "sha256-weu+XoC0ty6Dx4C96yDwWMOTcoBrifJabcsHIxJGUIU=";
      };

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
            templates = "${finalAttrs.passthru.templates}/templates";
          }
          # See available templates: <https://github.com/InioX/matugen-themes>
          ''
            mkdir -p $out

            cat <<EOF | tee config.toml
            [config]

            [templates.alacritty]
            input_path = "$templates/alacritty.toml"
            output_path = "$out/config/alacritty/colors/$name.toml"

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
