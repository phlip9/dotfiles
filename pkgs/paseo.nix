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
  patches = (prevAttrs.patches or [ ]) ++ [
    # Security: reject low-order Curve25519 public keys
    (fetchpatch {
      url = "https://github.com/getpaseo/paseo/commit/7bd8fb25b6cdebe813ae16da4d2df4d2895e7bc2.patch";
      hash = "sha256-NsITAF4UAU+OS3yt+NtvLnpNLEGx4UXWCYZadn4cQFQ=";
      # Upstream's Nix source filter excludes test files before patchPhase.
      includes = [ "packages/relay/src/crypto.ts" ];
    })
    # Kill full git process tree after timeout so ssh-askpass prompts don't
    # persist and stack up.
    ./paseo-kill-git-process-tree.patch
    # Add support for setting password via more secure PASEO_PASSWORD_FILE env.
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
