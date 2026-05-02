# Marinara Engine (lite mode)
#
# Lite mode disables local models (llama-server, onnxruntime,
# @huggingface/transformers) and only supports remote API providers.
#
# This is the unwrapped build. Use `marinara-engine` for the
# bubblewrap-sandboxed version.
{
  lib,
  stdenv,
  fetchFromGitHub,
  makeBinaryWrapper,
  nodejs_22,
  pnpm_10,
}:
let
  nodejs = nodejs_22;
  pnpm = pnpm_10;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "marinara-engine-unwrapped";
  version = "1.5.6";

  src = fetchFromGitHub {
    owner = "Pasta-Devs";
    repo = "Marinara-Engine";
    tag = "v${finalAttrs.version}";
    hash = "sha256-G0IzLS4kPgaokl7lAtbl9Hua4ntZddjbgKCp5LDB5LY=";
  };

  pnpmDeps = pnpm.fetchDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 3;
    hash = "sha256-3oLMsYPjC33jkR1DcSGStMQ11MTBpJP6BfmIMV7pG64=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm.configHook
    makeBinaryWrapper
  ];

  env = {
    MARINARA_LITE = "true";
    VITE_MARINARA_LITE = "true";
    NODE_OPTIONS = "--max-old-space-size=4096";
    # write-build-meta.mjs reads this instead of shelling out to git
    MARINARA_GIT_COMMIT = "aaaaaaaaaaaa";
  };

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,lib/marinara-engine}

    # Workspace manifests (pnpm module resolution needs these)
    cp package.json pnpm-workspace.yaml $out/lib/marinara-engine/
    cp -a node_modules $out/lib/marinara-engine/

    # Each workspace package: manifest + build output + local node_modules
    for pkg in shared server client; do
      mkdir -p "$out/lib/marinara-engine/packages/$pkg"
      cp "packages/$pkg/package.json" "$out/lib/marinara-engine/packages/$pkg/"
      cp -a "packages/$pkg/dist" "$out/lib/marinara-engine/packages/$pkg/"
      if [ -d "packages/$pkg/node_modules" ]; then
        cp -a "packages/$pkg/node_modules" \
          "$out/lib/marinara-engine/packages/$pkg/"
      fi
    done

    # Strip heavy native deps disabled by MARINARA_LITE
    rm -rf \
      $out/lib/marinara-engine/node_modules/.pnpm/onnxruntime-node@* \
      $out/lib/marinara-engine/node_modules/.pnpm/onnxruntime-web@* \
      $out/lib/marinara-engine/node_modules/.pnpm/onnxruntime-common@* \
      $out/lib/marinara-engine/node_modules/onnxruntime-node \
      $out/lib/marinara-engine/node_modules/onnxruntime-web \
      $out/lib/marinara-engine/node_modules/onnxruntime-common \
      $out/lib/marinara-engine/node_modules/.pnpm/@huggingface+transformers@* \
      $out/lib/marinara-engine/node_modules/@huggingface

    # Wrapper: run the server with lite-mode env set
    makeBinaryWrapper ${lib.getExe nodejs} $out/bin/marinara-engine \
      --inherit-argv0 \
      --set MARINARA_LITE true \
      --set NODE_ENV production \
      --add-flags $out/lib/marinara-engine/packages/server/dist/index.js

    runHook postInstall
  '';

  # pnpm node_modules contain internal symlinks that may dangle after
  # we strip onnxruntime / huggingface packages above.
  dontCheckForBrokenSymlinks = true;

  meta = {
    homepage = "https://github.com/Pasta-Devs/Marinara-Engine";
    license = lib.licenses.agpl3Only;
    mainProgram = "marinara-engine";
    platforms = lib.platforms.linux;
  };
})
