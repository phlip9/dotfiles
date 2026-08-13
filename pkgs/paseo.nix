# Paseo daemon + CLI with password-file support for runtime secrets.
{
  callPackage,
  fetchpatch,
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
    npmDepsHash = "sha256-i5PbVUe2Ec+GtghV9IpCJQJ9hcUT5hFhmxneNvoD584=";
  };
in

upstreamPaseo.overrideAttrs (prevAttrs: {
  # Keep credentials out of the process environment. Upstream supports only
  # plaintext PASEO_PASSWORD or a bcrypt hash in mutable config.json.
  patches = (prevAttrs.patches or [ ]) ++ [
    (fetchpatch {
      url = "https://github.com/getpaseo/paseo/commit/7bd8fb25b6cdebe813ae16da4d2df4d2895e7bc2.patch";
      hash = "sha256-NsITAF4UAU+OS3yt+NtvLnpNLEGx4UXWCYZadn4cQFQ=";
      # Upstream's Nix source filter excludes test files before patchPhase.
      includes = [ "packages/relay/src/crypto.ts" ];
    })
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
