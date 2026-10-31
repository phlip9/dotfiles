# GitHub stacked PRs CLI extension
{
  gh-stack,
  gitMinimal,
}:

gh-stack.overrideAttrs (
  finalAttrs: prevAttrs: {
    version = "0.3.0";
    src = prevAttrs.src.override {
      tag = "v${finalAttrs.version}";
      hash = "sha256-dENuxVuz68Y7P8WW5C7pzVbfJRxGMGIKQ2AnWrTacOs=";
    };
    vendorHash = "sha256-y+eTfmZTdSkHh943o/XtFrrMWv/lxvWekKUp/JKb0h4=";

    # Upstream integration tests create and rebase real Git repos.
    nativeCheckInputs = (prevAttrs.nativeCheckInputs or [ ]) ++ [ gitMinimal ];
  }
)
