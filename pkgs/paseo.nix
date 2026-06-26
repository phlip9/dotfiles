# Paseo daemon + CLI with bundled browser web UI.
{
  lib,
  callPackage,
  sources,
}:

let
  upstreamPaseo = callPackage (sources.paseo + "/nix/package.nix") {
    npmDepsHash = "sha256-o+VzG7lK0qpyUXF4F5Hk08ooW5CPoZSsOG7DyIReUKQ=";
  };
in

upstreamPaseo.overrideAttrs (prevAttrs: {
  src = lib.cleanSourceWith {
    src = sources.paseo;
    filter =
      path: _type:
      let
        baseName = builtins.baseNameOf path;
        relPath = lib.removePrefix (toString sources.paseo) path;
      in
      # Keep the Expo web app source/assets so `build:daemon-web-ui` can embed
      # the browser UI, but skip native/desktop/website-only payloads.
      !(lib.hasPrefix "/packages/app/android" relPath)
      && !(lib.hasPrefix "/packages/app/ios" relPath)
      && !(lib.hasPrefix "/packages/website/src" relPath)
      && !(lib.hasPrefix "/packages/website/public" relPath)
      && !(lib.hasPrefix "/packages/desktop/src" relPath)
      && !(lib.hasPrefix "/packages/desktop/src-tauri" relPath)
      && !(lib.hasSuffix ".test.ts" baseName)
      && !(lib.hasSuffix ".e2e.test.ts" baseName)
      && baseName != "node_modules"
      && baseName != ".git"
      && baseName != ".paseo"
      && baseName != ".DS_Store";
  };

  patches = (prevAttrs.patches or [ ]) ++ [
    ./paseo-password-file.patch
  ];

  postBuild = ''
    npm run build:daemon-web-ui
  '';

  postInstall = ''
    cp -a packages/server/dist/server/web-ui \
      $out/lib/paseo/packages/server/dist/server/
  '';
})
