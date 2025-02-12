# Anthropic Claude desktop and extensions
{
  config,
  phlipPkgs,
  pkgs,
  ...
}: {
  # Claude Desktop config
  home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
    enable = pkgs.hostPlatform.isDarwin;
    source = pkgs.writers.writeJSON "claude_desktop_config.json" {
      mcpServers = {
        # fs access (with approval ofc)
        filesystem = {
          command = "${phlipPkgs.mcp-server-filesystem}/bin/mcp-server-filesystem";
          # args: list of dirs the agent can access _only after approval_. The
          # agent can't access anything outside these dirs; the chat UI won't
          # even ask for approval.
          args = [
            "${config.home.homeDirectory}/dev"
          ];
        };
      };
    };
  };
}
