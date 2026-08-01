# claude-agent-acp - ACP adapter for Anthropic claude code CLI
{
  buildNpmPackage,
  claude-code,
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
  pname = "claude-agent-acp";
  version = "0.64.0";

  src = fetchFromGitHub {
    owner = "agentclientprotocol";
    repo = "claude-agent-acp";
    tag = "v${finalAttrs.version}";
    hash = "sha256-DBWsdGNbjkC1CzGwCpySOr07ruGkDdybfjkXI+3HXtA=";
  };

  npmDepsHash = "sha256-CRJbFoFjQLvzrs4sWGGNlbxlh05Z7i29oT5np/udqbc=";

  npmInstallFlags = [
    "--legacy-peer-deps"
    "--omit=dev"
    "--omit=optional"
  ];

  nativeBuildInputs = [
    esbuild
    makeBinaryWrapper
  ];

  # esbuild transpiles TypeScript directly, so only runtime deps are needed.
  # These three packages currently have no required transitive dependencies.
  postPatch = ''
    ${lib.getExe jq} 'del(.devDependencies)' \
      package.json > package.json.tmp
    mv package.json.tmp package.json

    ${lib.getExe jq} '
      "node_modules/@agentclientprotocol/sdk" as $acpSdk
      | "node_modules/@anthropic-ai/claude-agent-sdk" as $claudeSdk
      | .packages[""].dependencies as $runtimeDependencies
      | del(
          .packages[""].devDependencies,
          .packages[$acpSdk].peerDependencies,
          .packages[$claudeSdk].optionalDependencies,
          .packages[$claudeSdk].peerDependencies,
          .packages[$claudeSdk].peerDependenciesMeta
        )
      | .packages |= with_entries(
          select(
            .key == ""
            or $runtimeDependencies[.key | ltrimstr("node_modules/")] != null
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
      --banner:js=${lib.escapeShellArg esbuildBanner}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 dist/index.js $out/libexec/claude-agent-acp/index.js
    install -Dm644 LICENSE $out/share/licenses/claude-agent-acp/LICENSE
    mkdir -p $out/bin
    makeBinaryWrapper \
      ${lib.getExe nodejs-slim_24} \
      $out/bin/claude-agent-acp \
      --set CLAUDE_CODE_EXECUTABLE ${lib.getExe claude-code} \
      --add-flags $out/libexec/claude-agent-acp/index.js

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  postVersionCheck = ''
    $out/bin/claude-agent-acp --cli --version > /dev/null
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    changelog = "https://github.com/agentclientprotocol/claude-agent-acp/releases/tag/v${finalAttrs.version}";
    description = "ACP-compatible coding agent powered by the Claude Agent SDK";
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp";
    license = lib.licenses.asl20;
    mainProgram = "claude-agent-acp";
    inherit (claude-code.meta) platforms;
  };
})
