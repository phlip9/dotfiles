# Paseo daemon + CLI with password-file support for runtime secrets.
{
  callPackage,
  sources,
}:

let
  # fetchNpmDeps output differs across nixpkgs revisions. Keep the hash for
  # this repo's pinned nixpkgs while upstream maintains the package logic.
  upstreamPaseo = callPackage (sources.paseo + "/nix/package.nix") {
    npmDepsHash = "sha256-FbAuGkXHC6uCLED4X6vOW/T5eUrdxAxNZME6gWsc0w0=";
  };
in

upstreamPaseo.overrideAttrs (prevAttrs: {
  # Keep credentials out of the process environment. Upstream supports only
  # plaintext PASEO_PASSWORD or a bcrypt hash in mutable config.json.
  patches = (prevAttrs.patches or [ ]) ++ [
    ./paseo-password-file.patch
  ];
})
