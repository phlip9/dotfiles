# GitHub stacked PRs CLI extension
{
  gh-stack,
  gitMinimal,
}:

gh-stack.overrideAttrs (
  finalAttrs: prevAttrs: {
    version = "0.1.1";
    src = prevAttrs.src.override {
      tag = "v${finalAttrs.version}";
      hash = "sha256-jwfqiCnCOOW0AKA52hbgvCCoLzfFX+QfM+vXABkzZgw=";
    };
    vendorHash = "sha256-0Xtr/MOpX4u5GnbRdNxKPA0GpSzi8PIbVc9MmP05De4=";

    # Upstream integration tests create and rebase real Git repos.
    nativeCheckInputs = (prevAttrs.nativeCheckInputs or [ ]) ++ [ gitMinimal ];
  }
)
