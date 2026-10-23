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
    npmDepsHash = "sha256-ObBdUmNSW+vDjzA7EbCDfZrB0nYDmcWmWe+UCoTMh/M=";
  };
in

upstreamPaseo.overrideAttrs (prevAttrs: {
  # Upstream changed to Apache-2.0 in v0.7.0 but has not updated
  # nix/package.nix.
  meta = prevAttrs.meta // {
    license = lib.licenses.asl20;
  };

  patches = (prevAttrs.patches or [ ]) ++ [
    # Kill full git process tree after timeout so ssh-askpass prompts don't
    # persist and stack up.
    ./paseo-kill-git-process-tree.patch
    # Add support for setting password via more secure PASEO_PASSWORD_FILE env.
    ./paseo-password-file.patch
    # Require the daemon password on relay connections. Upstream admits relay
    # clients w/o a credential, so the daemon public key alone grants owner.
    ./paseo-require-relay-password.patch
    # Hard-disable the Paseo Cloud hub control channel, which attaches
    # pre-admitted sockets that bypass the daemon password.
    ./paseo-disable-hub.patch
    # Never fetch third-party plugin code from a registry, npm, or git.
    ./paseo-disable-plugin-installs.patch
    # Don't leak PASEO_PASSWORD{,_FILE} into agent and terminal envs.
    ./paseo-scrub-secret-env.patch
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
