# Update with `./pkgs/claude-code/update.sh`
{
  buildNpmPackage,
  fetchzip,
  versionCheckHook,
}:
buildNpmPackage (final: {
  pname = "claude-code";
  version = "2.1.21";

  src = fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${final.version}.tgz";
    hash = "sha256-WO1tomN8587HApMOGV50TRwobd4jMUq1CqXUBD7YBH4=";
  };

  npmDepsHash = "sha256-R5ZSCef6CP5v4uGycVkQn4wz2waKuwQfyYkORg6NsDM=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  env.AUTHORIZED = "1";

  # Disable all telemetry, auto-updating, error reporting, etc...
  # <https://code.claude.com/docs/en/settings#environment-variables>
  postInstall = ''
    wrapProgram $out/bin/claude \
      --set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1 \
      --unset DEV
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgram = "${placeholder "out"}/bin/claude";
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    mainProgram = "claude";
  };
})
