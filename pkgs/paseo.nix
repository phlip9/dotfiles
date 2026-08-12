# Paseo daemon + CLI with password-file support for runtime secrets.
{
  callPackage,
  gnutar,
  lib,
  procps,
  sources,
  stdenv,
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

  # Paseo uses ps to manage process trees and tar to extract speech models.
  # Upstream's wrappers do not include their Linux providers in PATH.
  postFixup =
    (prevAttrs.postFixup or "")
    + lib.optionalString stdenv.hostPlatform.isLinux ''
      wrapProgram $out/bin/paseo \
        --prefix PATH : ${lib.makeBinPath [ procps ]}
      wrapProgram $out/bin/paseo-server \
        --prefix PATH : ${
          lib.makeBinPath [
            gnutar
            procps
          ]
        }
    '';
})
