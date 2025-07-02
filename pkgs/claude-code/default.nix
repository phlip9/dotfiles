{
  buildNpmPackage,
  fetchzip,
}:
buildNpmPackage rec {
  pname = "claude-code";
  version = "1.0.41";

  src = fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-x8Bxh0iKqf8AsMQ+7zutSh53DbCRzM9s6s6BQkdbyXc=";
  };

  npmDepsHash = "sha256-bUWMFEwoW/zKRdmuXLyVg34TjYSsqLGki8DajBc7zCc=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  AUTHORIZED = "1";

  # Disable all telemetry, auto-updating, error reporting, etc...
  # <https://docs.anthropic.com/en/docs/claude-code/settings#environment-variables>
  postInstall = ''
    wrapProgram $out/bin/claude \
      --set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    mainProgram = "claude";
  };
}
