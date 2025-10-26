# Claude MCP (Model Context Protocol) server for filesystem access
{
  buildNpmPackage,
  fetchzip,
}:
buildNpmPackage rec {
  pname = "mcp-server-filesystem";
  version = "2025.1.14";

  src = fetchzip {
    url = "https://registry.npmjs.org/@modelcontextprotocol/server-filesystem/-/server-filesystem-${version}.tgz";
    hash = "sha256-lBiPPGcxdTYminK3Jli2lOGL6PdmQhP8mqAdFOvLlJ4=";
  };

  npmDepsHash = "sha256-fm60YWSVvjK7dqy5qX0mNrMH3aDr9vacDoycEwT8oSs=";

  # package.json:
  # 1. fetch and unzip .tgz somewhere
  # 2. copy over package.json from above to
  #    `pkgs/mcp-server-filesystem/package.json`
  # 3. remove "scripts" and "dev-dependencies" sections
  #
  # package-lock.json:
  # 1. $ cd pkgs/mcp-server-filesystem
  # 1. $ nix shell nixpkgs#nodejs
  # 2. $ npm install
  # 4. $ rm -rf node_modules
  postPatch = ''
    cp ${./package.json} package.json
    ln -sf ${./package-lock.json} package-lock.json
  '';

  npmFlags = [ "--omit=optional" ];

  dontNpmBuild = true;
}
