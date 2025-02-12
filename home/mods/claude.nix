# Anthropic Claude desktop and extensions
{phlipPkgs, ...}: {
  # TODO(phlip9): Claude desktop
  home.packages = [
    # a MCP provider for local filesystem access
    phlipPkgs.mcp-server-filesystem
  ];
}
