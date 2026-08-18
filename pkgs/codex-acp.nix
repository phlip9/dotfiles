# codex-acp - ACP adapter for the OpenAI Codex CLI
{
  buildNpmPackage,
  codex,
  esbuild,
  fetchFromGitHub,
  jq,
  lib,
  makeBinaryWrapper,
  nix-update-script,
  nodejs-slim_24,
  versionCheckHook,
}:

let
  # Some CommonJS dependencies need `require` in the ESM bundle.
  esbuildBanner = lib.concatStringsSep " " [
    "import { createRequire as __createRequire } from 'module';"
    "const require = __createRequire(import.meta.url);"
  ];
in

buildNpmPackage (finalAttrs: {
  pname = "codex-acp";
  version = "1.5.0";

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "codex-acp";
    tag = "v${finalAttrs.version}";
    hash = "sha256-klETNQ+/FjH7XqfcZqOKgfLTbWkPnPMTbqUmVCS5g8A=";
  };

  npmDepsHash = "sha256-V9JbmeFc/yZCw1PDl8ZbBZiMmGErWEUX/OVqMNHXiNg=";

  npmInstallFlags = [
    "--omit=dev"
    "--omit=optional"
    "--omit=peer"
  ];

  nativeBuildInputs = [
    esbuild
    makeBinaryWrapper
  ];

  # Remove the vendored Codex CLI and build-only dependencies.
  postPatch = ''
    ${lib.getExe jq} \
      'del(.dependencies["@openai/codex"], .devDependencies)' \
      package.json > package.json.tmp
    mv package.json.tmp package.json

    ${lib.getExe jq} '
      del(
        .packages[""].dependencies["@openai/codex"],
        .packages[""].devDependencies
      )
      | .packages |= with_entries(
          select(
            .key == ""
            or (
              (.key | startswith("node_modules/@openai/codex") | not)
              and (.value.dev != true)
            )
          )
        )
    ' package-lock.json > package-lock.json.tmp
    mv package-lock.json.tmp package-lock.json
  '';

  # Bundle runtime dependencies into a single Node entry point.
  buildPhase = ''
    runHook preBuild

    mkdir -p dist
    esbuild src/index.ts \
      --bundle \
      --minify \
      --platform=node \
      --target=node24 \
      --format=esm \
      --outfile=dist/index.js \
      --external:@openai/codex \
      --banner:js=${lib.escapeShellArg esbuildBanner}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 dist/index.js $out/libexec/codex-acp/index.js
    install -Dm644 LICENSE $out/share/licenses/codex-acp/LICENSE
    mkdir -p $out/bin
    makeBinaryWrapper \
      ${lib.getExe nodejs-slim_24} \
      $out/bin/codex-acp \
      --set CODEX_PATH ${lib.getExe codex} \
      --add-flags $out/libexec/codex-acp/index.js

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  postVersionCheck = ''
    $out/bin/codex-acp cli --help > /dev/null
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    changelog = "https://github.com/agentclientprotocol/codex-acp/releases/tag/v${finalAttrs.version}";
    description = "ACP adapter for the OpenAI Codex CLI";
    homepage = "https://github.com/agentclientprotocol/codex-acp";
    license = lib.licenses.asl20;
    mainProgram = "codex-acp";
    inherit (codex.meta) platforms;
  };
})
