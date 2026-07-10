# Marinara Engine (lite mode)
#
# Lite mode disables local models (llama-server, onnxruntime,
# @huggingface/transformers) and only supports remote API providers.
#
# This is the unwrapped build. Use `marinara-engine` for the
# bubblewrap-sandboxed version.
{
  bash,
  fetchFromGitHub,
  fetchPnpmDeps,
  lib,
  makeBinaryWrapper,
  nix-update-script,
  nodejs-slim_24,
  pnpm_10,
  pnpmConfigHook,
  stdenv,
}:
let
  nodejs = nodejs-slim_24;
  pnpm = pnpm_10.override { nodejs-slim = nodejs; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "marinara-engine-unwrapped";
  version = "2.1.1";

  src = fetchFromGitHub {
    owner = "Pasta-Devs";
    repo = "Marinara-Engine";
    tag = "v${finalAttrs.version}";
    hash = "sha256-14sKnswQ1W+2mroammaEUZlPC80JGngX8rngQMH3hJg=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    # override upstream's .npmrc store-dir with nix FOD store.
    prePnpmInstall = ''
      pnpm config set --location project store-dir "$storePath"
    '';
    hash = "sha256-TIv+Jw4go0Y0UKOoa1BRGuytwoR5J4yCDfTnX1CUpNA=";
  };

  nativeBuildInputs = [
    nodejs
    pnpmConfigHook
    pnpm
    makeBinaryWrapper
  ];

  postPatch = ''
    substituteInPlace packages/server/src/services/professor-mari/workspace-agent.service.ts \
      --replace-fail '"/bin/sh"' '"${lib.getExe bash}"'
  '';

  env = {
    MARINARA_LITE = "true";
    VITE_MARINARA_LITE = "true";
    NODE_OPTIONS = "--max-old-space-size=4096";
    # write-build-meta.mjs reads this instead of shelling out to git
    MARINARA_GIT_COMMIT = "aaaaaaaaaaaa";
  };

  # override upstream's .npmrc store-dir with nix FOD store.
  prePnpmInstall = ''
    pnpm config set --location project store-dir "$STORE_PATH"
  '';

  buildPhase = ''
    runHook preBuild

    # pnpmConfigHook disables lifecycle scripts. esbuild is build-only and needs
    # the binary before Vite runs.
    pnpm rebuild esbuild
    pnpm build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    app_dir="$out/lib/marinara-engine"
    mkdir -p "$app_dir" $out/bin

    # recreate the dependency tree with production dependencies only.
    rm -rf .pnpm node_modules packages/*/node_modules
    pnpm install --offline --prod --ignore-scripts --frozen-lockfile

    # restore workspace manifests (pnpm module resolution needs these)
    cp package.json pnpm-workspace.yaml "$app_dir/"

    # .npmrc config sets pnpm's virtual store inside the workspace root
    cp -a .pnpm node_modules "$app_dir/"

    # for each workspace package: cp manifest + build output + node_modules
    for pkg in shared server client; do
      pkg_dir="$app_dir/packages/$pkg"
      mkdir -p "$pkg_dir"
      cp "packages/$pkg/package.json" "$pkg_dir/"
      cp -a "packages/$pkg/dist" "$pkg_dir/"
      if [ -d "packages/$pkg/node_modules" ]; then
        cp -a "packages/$pkg/node_modules" "$pkg_dir/"
      fi
    done

    # user guides served by the in-app documentation viewer.
    cp -a docs "$app_dir/"

    # strip local inference runtimes disabled by MARINARA_LITE.
    rm -rf \
      "$app_dir"/.pnpm/onnxruntime-node@* \
      "$app_dir"/.pnpm/onnxruntime-web@* \
      "$app_dir"/packages/server/node_modules/onnxruntime-node \
      "$app_dir"/packages/server/node_modules/onnxruntime-web
    find "$app_dir" -xtype l -delete

    # catch incomplete pnpm layouts during the build instead of at startup.
    ${lib.getExe nodejs} -e \
      "for (const dep of ['fastify', '@fastify/cors', 'sharp']) require.resolve(dep, { paths: ['$app_dir/packages/server'] })"

    # wrapper: run the server with lite-mode env set
    makeBinaryWrapper ${lib.getExe nodejs} $out/bin/marinara-engine \
      --inherit-argv0 \
      --set MARINARA_LITE true \
      --set NODE_ENV production \
      --add-flags $out/lib/marinara-engine/packages/server/dist/index.js

    runHook postInstall
  '';

  passthru = {
    inherit nodejs;
    updateScript = nix-update-script { };
  };

  meta = {
    homepage = "https://github.com/Pasta-Devs/Marinara-Engine";
    license = lib.licenses.agpl3Only;
    mainProgram = "marinara-engine";
    platforms = lib.platforms.linux;
  };
})
