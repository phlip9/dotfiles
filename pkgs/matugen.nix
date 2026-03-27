# A cross-platform material you and base16 color generation tool
#
# See: pkgs/matugen-themes.nix
{
  fetchFromGitHub,
  linkFarm,
  matugen-themes,
  nix-update-script,
  noctalia-shell,
  runCommand,
  rustPlatform,
}:

let
  matugen = rustPlatform.buildRustPackage (finalAttrs: {
    pname = "matugen";
    version = "4.1.0";

    src = fetchFromGitHub {
      owner = "InioX";
      repo = "matugen";
      tag = "v${finalAttrs.version}";
      hash = "sha256-xzwMDWb6pF3oStVoS8enNhpYptxdnB1NSIO7dUH6/qk=";
    };

    cargoHash = "sha256-bfvlPiTlPQeedo+ikHXSI8NqdA5R5M7gCsgx7srYsMQ=";

    cargoBuildFlags = "-p matugen --bin matugen";

    meta = {
      mainProgram = "matugen";
    };

    passthru = {
      updateScript = nix-update-script { };

      # noctalia-shell color templates
      noctalia-templates =
        runCommand "noctalia-templates"
          {
            src = noctalia-shell.src;
          }
          ''
            mkdir $out
            cp -r $src/Assets/Templates/. $out/
          '';

      # collect all templates
      templates = linkFarm "templates" {
        matugen = finalAttrs.passthru.matugen-themes;
        noctalia = finalAttrs.passthru.noctalia-templates;
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
            inherit (finalAttrs.passthru) templates;
          }
          # See available templates: <https://github.com/InioX/matugen-themes>
          ''
            mkdir -p $out

            cat <<EOF | tee config.toml
            [config]

            # [templates.alacritty]
            # input_path = "$templates/matugen/alacritty.toml"
            # output_path = "$out/config/alacritty/colors/$name.toml"

            [templates.fuzzel]
            input_path = "$templates/matugen/fuzzel.ini"
            output_path = "$out/config/fuzzel/colors/$name.ini"

            [templates.gtk3]
            input_path = "$templates/matugen/gtk-colors.css"
            output_path = "$out/config/gtk-3.0/colors/$name.css"

            [templates.gtk4]
            input_path = "$templates/matugen/gtk-colors.css"
            output_path = "$out/config/gtk-4.0/colors/$name.css"

            [templates.niri]
            input_path = "$templates/matugen/niri-colors.kdl"
            output_path = "$out/config/niri/colors/$name.kdl"

            [templates.noctalia]
            input_path = "$templates/noctalia/noctalia.json"
            output_path = "$out/config/noctalia/colors.json"

            [templates.qt5ct]
            input_path = "$templates/matugen/qtct-colors.conf"
            output_path = "$out/config/qt5ct/colors/$name.conf"

            [templates.qt6ct]
            input_path = "$templates/matugen/qtct-colors.conf"
            output_path = "$out/config/qt6ct/colors/$name.conf"

            [templates.tmux]
            input_path = "$templates/matugen/tmux-colors.conf"
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
