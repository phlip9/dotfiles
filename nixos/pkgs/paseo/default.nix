# Paseo daemon + CLI + bundled web UI, split into cached sub-derivations:
#
#   npmDeps (FOD) -> nodeModules -> shared -+-> server -+-> paseo
#                                           +-> webUi  -+
#
# Each sub-derivation receives only its own source paths and the matching hunks
# from `patches`, so editing a server-only patch skips rebuilding nodeModules,
# shared, and webUi (and vice versa).
{
  autoPatchelfHook,
  buildNpmPackage,
  fetchNpmDeps,
  lib,
  libuv,
  makeBinaryWrapper,
  nodejs_22,
  procps,
  python3,
  runCommand,
  sources,
  stdenv,
}:

let
  pname = "paseo";
  version =
    (builtins.fromJSON (builtins.readFile (sources.paseo + "/package.json")))
    .version;

  # Single ordered list of downstream patches. `patch-list.sh` (used by
  # paseo-dev and paseo-upgrade) reads `paseo.patches` directly.
  patches = [
    # Kill full git process tree after timeout so ssh-askpass prompts don't
    # persist and stack up.
    ./paseo-kill-git-process-tree.patch
    # Add support for setting password via more secure PASEO_PASSWORD_FILE env.
    ./paseo-password-file.patch
    # Hard-disable the Paseo Cloud hub control channel, which attaches
    # pre-admitted sockets that bypass the daemon password.
    ./paseo-disable-hub.patch
    # Never fetch third-party plugin code or registry listings from a registry,
    # npm, or git.
    ./paseo-disable-plugin-installs.patch
    # Don't leak PASEO_PASSWORD{,_FILE} into agent and terminal envs.
    ./paseo-scrub-secret-env.patch
    # Stop multi-KB log lines from flooding the journal. Silence esp. bad ones.
    ./paseo-quiet-logs.patch
    # Show more lines of context (vs git's default 3) in Diff and commit diffs.
    ./paseo-diff-context.patch
    # Show the full commit message when viewing a single commit: pinned
    # subject, then author, date, sha, and body scrolling w/ the diff.
    ./paseo-commit-message.patch
    # Compile built-in plugins during the build. Runtime only reads artifacts
    # and never needs esbuild or TypeScript in its dependency closure.
    ./paseo-precompile-plugins.patch
    # Disable provider CLI release update checks and in-place self-updaters;
    # provider binaries are managed declaratively by Nix.
    ./paseo-disable-provider-updates.patch
  ];

  sharedPackages = [
    "protocol"
    "relay"
    "client"
    "highlight"
    "plugin"
  ];

  rootTsFiles = [
    "package.json"
    "tsconfig.json"
    "tsconfig.base.json"
  ];

  # --- Source and patch slicing --- #

  # Split a unified git diff into `{ old, new, files, text }` sections.
  # Fails closed on unparseable headers (spaces, git-quoted paths, malformed
  # diffs) so a hardening hunk can never be silently dropped.
  parsePatchSections =
    patch:
    let
      parts = builtins.split "\ndiff --git " ("\n" + builtins.readFile patch);
      # Element 0 is any preamble before the first `diff --git `; drop it.
      rawSections = lib.filter (part: builtins.isString part && part != "") (
        if parts == [ ] then [ ] else builtins.tail parts
      );
      parseSection =
        section:
        let
          match = builtins.match "a/([^ \n]+) b/([^ \n]+)\n.*" section;
          firstLine = builtins.head (lib.splitString "\n" section);
        in
        if match == null then
          throw "paseo: unparseable diff header in ${toString patch}: diff --git ${firstLine}"
        else
          let
            oldFile = builtins.elemAt match 0;
            newFile = builtins.elemAt match 1;
          in
          {
            old = oldFile;
            new = newFile;
            files =
              if oldFile == newFile then
                [ oldFile ]
              else
                [
                  oldFile
                  newFile
                ];
            text = "diff --git ${section}\n";
          };
    in
    if rawSections == [ ] then
      throw "paseo: patch contains no diff sections: ${toString patch}"
    else
      map parseSection rawSections;

  # Pure-Nix unified diff slicer: keep only file sections matching `pred` so
  # multi-workspace patches only invalidate the affected sub-derivations.
  slicePatches =
    scope: pred:
    lib.filter (sliced: sliced != null) (
      map (
        patch:
        let
          kept = lib.filter (sec: lib.any pred sec.files) (parsePatchSections patch);
        in
        if kept == [ ] then
          null
        else
          builtins.toFile "${scope}-${builtins.baseNameOf (toString patch)}" (
            lib.concatMapStrings (sec: sec.text) kept
          )
      ) patches
    );

  # Derive a sub-derivation's filtered `src`, sliced `patches`, and path
  # predicate from a single `{ name, dirs, files }` declaration.
  mkScope =
    {
      name,
      dirs,
      files ? rootTsFiles,
    }:
    let
      matchesPath =
        relPath:
        builtins.elem relPath files
        || lib.any (dir: relPath == dir || lib.hasPrefix "${dir}/" relPath) dirs;
    in
    {
      inherit matchesPath;
      patches = slicePatches name matchesPath;
      src = lib.cleanSourceWith {
        name = "paseo-${name}-src";
        src = sources.paseo;
        filter =
          path: type:
          let
            baseName = builtins.baseNameOf path;
            relPath = lib.removePrefix "/" (lib.removePrefix (toString sources.paseo) path);
            isTestOrJunk =
              lib.hasSuffix ".test.ts" baseName
              || lib.hasSuffix ".test.tsx" baseName
              || lib.hasSuffix "-test.ts" baseName
              || builtins.elem baseName [
                "node_modules"
                ".git"
                ".paseo"
                ".DS_Store"
              ];
            isAncestorDir =
              type == "directory"
              && (
                lib.any (dir: lib.hasPrefix "${relPath}/" dir) dirs
                || lib.any (file: lib.hasPrefix "${relPath}/" file) files
              );
          in
          !isTestOrJunk && (matchesPath relPath || isAncestorDir);
      };
    };

  # Workspaces pruned in prune-lockfile.py; exclude from rawNodeModulesSrc so
  # edits to their manifests do not invalidate `nodeModules`.
  droppedWorkspaces = [
    "packages/website"
    "packages/desktop"
  ];

  isNodeModulesPath =
    relPath:
    !(lib.any (ws: relPath == "${ws}/package.json") droppedWorkspaces)
    && (
      builtins.elem relPath [
        "package.json"
        "package-lock.json"
        "scripts/postinstall-patches.mjs"
      ]
      || lib.hasPrefix "patches/" relPath
      || (builtins.match "(packages/[^/]+|plugins)/package\\.json" relPath != null)
    );

  sharedScope = mkScope {
    name = "shared";
    dirs = map (pkg: "packages/${pkg}") sharedPackages;
  };

  serverScope = mkScope {
    name = "server";
    dirs = [
      "packages/server"
      "packages/cli"
      "plugins"
      "skills"
    ];
  };

  webUiScope = mkScope {
    name = "web-ui";
    dirs = [
      "packages/app"
      "packages/expo-two-way-audio"
    ];
  };

  # Guard against silently dropping a patch hunk or splitting a cross-scope
  # rename (which would fail to apply in the destination scope).
  assertAllPatchHunksMatched =
    let
      scopePreds = [
        isNodeModulesPath
        sharedScope.matchesPath
        serverScope.matchesPath
        webUiScope.matchesPath
      ];
      matchingScopes = relPath: map (pred: pred relPath) scopePreds;
      isKnown =
        relPath:
        lib.any (matched: matched) (matchingScopes relPath)
        || lib.hasPrefix ".artifacts/" relPath;
      allSections = lib.concatMap (
        patch: map (sec: sec // { inherit patch; }) (parsePatchSections patch)
      ) patches;
      unmatched = lib.unique (
        lib.filter (relPath: !(isKnown relPath)) (
          lib.concatMap (sec: sec.files) allSections
        )
      );
      crossScopeRenames = lib.filter (
        sec: sec.old != sec.new && matchingScopes sec.old != matchingScopes sec.new
      ) allSections;
    in
    if unmatched != [ ] then
      throw "paseo: patch hunks not matched by any sub-derivation: ${toString unmatched}"
    else if crossScopeRenames != [ ] then
      let
        bad = builtins.head crossScopeRenames;
      in
      throw "paseo: cross-scope rename unsupported (${bad.old} -> ${bad.new}) in ${toString bad.patch}"
    else
      true;

  # --- Shared shell helpers --- #

  # Copy prebuilt shared libraries into ./packages/ writable so workspace
  # node_modules symlinks can be attached and @vercel/nft traces local files.
  copySharedScript = ''
    for pkg in ${lib.escapeShellArgs sharedPackages}; do
      cp -a "${shared}/packages/$pkg" "packages/$pkg"
      chmod -R u+w "packages/$pkg"
    done
  '';

  # Populate ./node_modules with symlinks to `nodeModules` plus workspace
  # @getpaseo/* symlinks pointing at ./packages/*. Shadow `tsc` w/ upstream's
  # bundled `tsgo` (@typescript/native-preview) for ~10x faster TS emit while
  # keeping upstream's `npm run build` scripts intact.
  linkNodeModulesScript = ''
    mkdir -p node_modules node_modules/@getpaseo node_modules/.bin
    for entry in "${nodeModules}"/node_modules/* "${nodeModules}"/node_modules/.[!.]*; do
      [ -e "$entry" ] || continue
      base=$(basename "$entry")
      [ "$base" = "@getpaseo" ] || [ "$base" = ".bin" ] && continue
      ln -s "$entry" "node_modules/$base"
    done
    for bin in "${nodeModules}"/node_modules/.bin/*; do
      [ -e "$bin" ] || continue
      base=$(basename "$bin")
      [ "$base" = "tsc" ] && continue
      ln -s "$bin" "node_modules/.bin/$base"
    done
    ln -s "${nodeModules}/node_modules/.bin/tsgo" node_modules/.bin/tsc
    node -e '
      const fs = require("node:fs");
      for (const dir of fs.readdirSync("packages")) {
        const manifest = "packages/" + dir + "/package.json";
        if (!fs.existsSync(manifest)) continue;
        const { name } = JSON.parse(fs.readFileSync(manifest, "utf8"));
        if (name && name.startsWith("@getpaseo/")) {
          fs.symlinkSync("../../packages/" + dir, "node_modules/" + name);
        }
      }
    '
    for ws_nm in "${nodeModules}"/packages/*/node_modules; do
      [ -d "$ws_nm" ] || continue
      ws_rel="packages/$(basename "$(dirname "$ws_nm")")"
      [ -d "$ws_rel" ] && ln -s "$ws_nm" "$ws_rel/node_modules"
    done
    if [ -d "${nodeModules}/plugins/node_modules" ] && [ -d plugins ]; then
      ln -s "${nodeModules}/plugins/node_modules" plugins/node_modules
    fi
    export PATH="$PWD/node_modules/.bin:$PATH"
  '';

  # --- 1. npmDeps (FOD) --- #

  npmDepsHash = "sha256-BuetwmBi9pE2DIWvnIHnDv1BYj4tiz5C0759r6I4Yss=";

  # Keep only lockfile + workspace manifests + upstream patches for npm ci.
  rawNodeModulesSrc = lib.cleanSourceWith {
    name = "paseo-node-modules-src-raw";
    src = sources.paseo;
    filter =
      path: type:
      let
        relPath = lib.removePrefix "/" (lib.removePrefix (toString sources.paseo) path);
      in
      isNodeModulesPath relPath
      || (
        type == "directory"
        && (
          builtins.elem relPath [
            "packages"
            "plugins"
            "scripts"
            "patches"
          ]
          || lib.hasPrefix "patches/" relPath
          || (
            builtins.match "packages/[^/]+" relPath != null
            && !(builtins.elem relPath droppedWorkspaces)
          )
        )
      );
  };

  # Prune unused workspaces, dev/test/lint tools, mobile-native packages,
  # sherpa-onnx, and non-linux-x64 binaries before fetchNpmDeps and npm ci.
  nodeModulesSrc = stdenv.mkDerivation {
    name = "paseo-node-modules-src";
    src = rawNodeModulesSrc;
    patches = slicePatches "node-modules" isNodeModulesPath;
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out"
      cp -a . "$out/"
      chmod -R u+w "$out"
      ${lib.getExe python3} ${./prune-lockfile.py} "$out"
    '';
    dontFixup = true;
  };

  npmDeps = fetchNpmDeps {
    name = "${pname}-${version}-npm-deps";
    src = nodeModulesSrc;
    hash = npmDepsHash;
  };

  # --- 2. nodeModules (cached per lockfile + upstream patches) --- #

  nodeModules = buildNpmPackage {
    pname = "paseo-node-modules";
    inherit version npmDeps;
    src = nodeModulesSrc;

    nodejs = nodejs_22;

    # Run postinstall and `npm rebuild node-pty` explicitly in buildPhase so
    # arbitrary package install scripts cannot run during npmConfigHook.
    npmRebuildFlags = [ "--ignore-scripts" ];

    nativeBuildInputs = [
      python3 # node-gyp for node-pty compilation
    ];

    buildInputs = [
      libuv # node-pty headers
    ];

    dontNpmBuild = true;

    # Upstream builds w/ `--ignore-scripts`, so postinstall never applies
    # `patches/*.patch` to node_modules (getpaseo/paseo#7673).
    buildPhase = ''
      runHook preBuild
      npm run postinstall
      npm rebuild node-pty
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      rm -rf node_modules/@getpaseo
      mkdir -p "$out"
      cp -a node_modules "$out/node_modules"
      for ws_nm in packages/*/node_modules plugins/node_modules; do
        [ -d "$ws_nm" ] || continue
        mkdir -p "$out/$(dirname "$ws_nm")"
        cp -a "$ws_nm" "$out/$ws_nm"
      done
      runHook postInstall
    '';

    # npmConfigHook already patched shebangs; native libs are patchelf'd in server.
    dontFixup = true;
  };

  # --- 3. shared workspace libraries --- #

  shared = stdenv.mkDerivation {
    pname = "paseo-shared";
    inherit version;
    inherit (sharedScope) src patches;

    nativeBuildInputs = [ nodejs_22 ];

    buildPhase = ''
      runHook preBuild
      ${linkNodeModulesScript}

      # generate-validation-aot.mjs patches zod-aot in place before running.
      rm node_modules/zod-aot
      cp -a "${nodeModules}/node_modules/zod-aot" node_modules/zod-aot
      chmod -R u+w node_modules/zod-aot

      # Wave 1 (independent packages) in parallel.
      (npm run build --workspace=@getpaseo/protocol) &
      pid_protocol=$!
      (npm run build --workspace=@getpaseo/relay) &
      pid_relay=$!
      (npm run build --workspace=@getpaseo/highlight) &
      pid_highlight=$!
      wait "$pid_protocol"
      wait "$pid_relay"
      wait "$pid_highlight"

      # Wave 2: client (protocol and relay are already built above).
      (cd packages/client && tsc -p tsconfig.json --incremental false)

      # Wave 3: plugin (imports types from protocol and client).
      npm run build --workspace=@getpaseo/plugin

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      for pkg in ${lib.escapeShellArgs sharedPackages}; do
        mkdir -p "$out/packages/$pkg"
        cp -a "packages/$pkg/package.json" "packages/$pkg/dist" \
          "$out/packages/$pkg/"
      done
      runHook postInstall
    '';

    dontFixup = true;
  };

  # --- 4a. server + cli + traced runtime closure --- #

  server = stdenv.mkDerivation {
    pname = "paseo-server";
    inherit version;
    inherit (serverScope) src patches;

    nativeBuildInputs = [
      autoPatchelfHook
      nodejs_22
    ];

    buildInputs = [
      libuv
      stdenv.cc.cc.lib # libstdc++ for node-pty native addon
    ];

    disallowedReferences = [ nodeModules ];

    postPatch = ''
      # dev-runner.ts is only used for `npm run dev` and imports `concurrently`
      # (pruned from nodeModules).
      substituteInPlace packages/server/tsconfig.scripts.json \
        --replace-fail '"scripts/dev-runner.ts",' ""

      # Local speech (sherpa-onnx, silero_vad.onnx, tar) is pruned from this
      # package. Default dictation off (voice mode is already off by default)
      # and disable local provider/model-library initialization so standalone
      # launches never spawn a missing worker or download speech models.
      substituteInPlace packages/server/src/server/speech/speech-config-resolver.ts \
        --replace-fail \
          'export const DICTATION_ENABLED_BY_DEFAULT = true;' \
          'export const DICTATION_ENABLED_BY_DEFAULT = false;'
      substituteInPlace packages/server/src/server/speech/providers/local/config.ts \
        --replace-fail \
          'const includeProviderConfig = shouldIncludeLocalProviderConfig(params);' \
          'const includeProviderConfig = shouldIncludeLocalProviderConfig(params) && false;'
      substituteInPlace packages/server/src/server/speech/speech-runtime.ts \
        --replace-fail \
          'const modelLibrary = speechConfig' \
          'const modelLibrary = speechConfig?.local'

      # Keep esbuild module wrapper paths relative to the workspace instead of
      # embedding /nix/store/...-paseo-node-modules paths into shipped bundles.
      for script in \
        packages/server/scripts/build-terminal-worker.mjs \
        packages/server/scripts/build-opencode-bridge-plugin.mjs; do
        substituteInPlace "$script" \
          --replace-fail 'bundle: true,' 'bundle: true, preserveSymlinks: true,'
      done
    '';

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      ${copySharedScript}
      ${linkNodeModulesScript}

      # Build server lib first, then run server scripts, cli, and built-in
      # plugin precompilation concurrently.
      npm run build:lib --workspace=@getpaseo/server
      (npm run build:scripts --workspace=@getpaseo/server) &
      pid_scripts=$!
      (npm run build --workspace=@getpaseo/cli) &
      pid_cli=$!
      (node packages/server/scripts/precompile-builtin-plugins.mjs) &
      pid_plugins=$!
      wait "$pid_scripts"
      wait "$pid_cli"
      wait "$pid_plugins"

      # Swap in the precompiled-artifact plugin loader after precompilation.
      cp packages/server/scripts/plugin-compiler-runtime.mjs \
        packages/server/dist/server/server/plugins/compiler-build.js

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/paseo"
      NODE_PRESERVE_SYMLINKS=1 node ${./install-server.mjs} \
        "${nodeModules}" "$out/lib/paseo"
      # Shell hooks invoke the retained CLI bin directly, without a system Node.
      patchShebangs --build "$out/lib/paseo"
      runHook postInstall
    '';

    dontStrip = true;
  };

  # --- 4b. webUi (Expo web bundle + precompressed assets) --- #

  # Standalone tsconfig for expo-two-way-audio so we don't depend on
  # expo-module-scripts (which drags in ~400 jest/eslint packages).
  expoTwoWayAudioTsconfig = builtins.toFile "expo-two-way-audio-tsconfig.json" (
    builtins.toJSON {
      compilerOptions = {
        rootDir = "./src";
        outDir = "./build";
        target = "esnext";
        module = "esnext";
        moduleResolution = "bundler";
        moduleDetection = "force";
        jsx = "react-native";
        lib = [
          "dom"
          "DOM.Iterable"
          "esnext"
        ];
        esModuleInterop = true;
        skipLibCheck = true;
        strict = true;
        declaration = true;
      };
      include = [ "./src" ];
      exclude = [
        "**/__mocks__/*"
        "**/__tests__/*"
      ];
    }
  );

  webUi = stdenv.mkDerivation {
    pname = "paseo-web-ui";
    inherit version;
    inherit (webUiScope) src patches;

    nativeBuildInputs = [ nodejs_22 ];

    disallowedReferences = [ nodeModules ];

    postPatch = ''
      cp ${expoTwoWayAudioTsconfig} packages/expo-two-way-audio/tsconfig.nix.json

      # Replace Metro's JS Terser minifier w/ esbuild (already in node_modules).
      cp ${./metro-minify-esbuild.cjs} packages/app/metro-minify-esbuild.cjs
      substituteInPlace packages/app/metro.config.cjs \
        --replace-fail \
          'module.exports = config;' \
          'config.transformer = { ...config.transformer, minifierPath: path.resolve(__dirname, "metro-minify-esbuild.cjs") }; module.exports = config;'
    '';

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      export EXPO_NO_TELEMETRY=1
      ${copySharedScript}
      ${linkNodeModulesScript}

      # Metro computes exported asset paths from realpath; copying expo-router
      # locally keeps its asset URLs workspace-relative instead of referencing
      # the nodeModules store path.
      rm node_modules/expo-router
      cp -a "${nodeModules}/node_modules/expo-router" node_modules/expo-router

      # Only expo-two-way-audio still needs TS emit before Expo web export.
      (cd packages/expo-two-way-audio && tsgo -p tsconfig.nix.json)
      (cd packages/app && expo export --platform web)

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      node ${./install-web-ui.mjs} packages/app/dist "$out"
      runHook postInstall
    '';

    dontFixup = true;
  };
in

# --- 5. Final lightweight assembly --- #
assert assertAllPatchHunksMatched;
runCommand "${pname}-${version}"
  {
    inherit pname version;
    nativeBuildInputs = [ makeBinaryWrapper ];
    passthru = {
      inherit
        patches
        npmDeps
        nodeModules
        shared
        server
        webUi
        ;
    };
    meta = {
      description = "Self-hosted daemon for Claude Code, Codex, and OpenCode";
      homepage = "https://github.com/getpaseo/paseo";
      license = lib.licenses.asl20;
      mainProgram = "paseo";
      # prune-lockfile.py filters native optional deps for x86_64-linux glibc.
      platforms = [ "x86_64-linux" ];
    };
  }
  ''
    mkdir -p "$out/bin"

    # Mirror server's layout w/ symlinks and attach the separately-built webUi
    # at packages/server/dist/server/web-ui (used by nixosTests.paseo and tools).
    linkChildrenExcept() {
      local src_dir=$1 dst_dir=$2 skip=''${3:-}
      mkdir -p "$dst_dir"
      (
        shopt -s dotglob nullglob
        for entry in "$src_dir"/*; do
          base=$(basename "$entry")
          [ "$base" = "$skip" ] && continue
          ln -s "$entry" "$dst_dir/$base"
        done
      )
    }

    linkChildrenExcept "${server}/lib/paseo" "$out/lib/paseo" packages
    linkChildrenExcept "${server}/lib/paseo/packages" "$out/lib/paseo/packages" server
    linkChildrenExcept "${server}/lib/paseo/packages/server" "$out/lib/paseo/packages/server" dist
    linkChildrenExcept "${server}/lib/paseo/packages/server/dist" "$out/lib/paseo/packages/server/dist" server
    linkChildrenExcept "${server}/lib/paseo/packages/server/dist/server" "$out/lib/paseo/packages/server/dist/server"
    ln -s "${webUi}" "$out/lib/paseo/packages/server/dist/server/web-ui"

    # Keep Paseo's runtime mode separate from NODE_ENV (which belongs to agents).
    # Known non-issue for our NixOS setup: `PASEO_WEB_UI_DIST_DIR` takes
    # precedence over persisted `features.webUi.distDir`, and CLI-launched
    # daemons (`paseo daemon start/restart/run`) resolve `${server}` directly
    # without `web-ui`. NixOS runs `paseo-server` via systemd w/o persisted
    # `distDir`.
    makeWrapper ${lib.getExe' nodejs_22 "node"} "$out/bin/paseo-server" \
      --add-flags "${server}/lib/paseo/packages/server/dist/scripts/supervisor-entrypoint.js" \
      --set PASEO_NODE_ENV production \
      --set-default PASEO_WEB_UI_DIST_DIR "${webUi}" \
      --prefix PATH : ${lib.makeBinPath [ procps ]}

    makeWrapper ${lib.getExe' nodejs_22 "node"} "$out/bin/paseo" \
      --add-flags "${server}/lib/paseo/packages/cli/dist/index.js" \
      --set NODE_PATH "${server}/lib/paseo/node_modules" \
      --prefix PATH : ${lib.makeBinPath [ procps ]}
  ''
