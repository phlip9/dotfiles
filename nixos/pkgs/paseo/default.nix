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
    npmDepsHash = "sha256-f2/UslxzI8mmz0rl9c1bQ0P2H6zbq96u5NEuao5u1fI=";
  };
in

upstreamPaseo.overrideAttrs (prevAttrs: {
  patches = (prevAttrs.patches or [ ]) ++ [
    # Kill full git process tree after timeout so ssh-askpass prompts don't
    # persist and stack up.
    ./paseo-kill-git-process-tree.patch
    # Add support for setting password via more secure PASEO_PASSWORD_FILE env.
    ./paseo-password-file.patch
    # Hard-disable the Paseo Cloud hub control channel, which attaches
    # pre-admitted sockets that bypass the daemon password.
    ./paseo-disable-hub.patch
    # Never fetch third-party plugin code or registry listings from a registry,
    # npm, or git.
    ./paseo-disable-plugin-installs.patch
    # Don't leak PASEO_PASSWORD{,_FILE} into agent and terminal envs.
    ./paseo-scrub-secret-env.patch
    # Stop multi-KB log lines from flooding the journal. Silence esp. bad ones.
    ./paseo-quiet-logs.patch
    # Show more lines of context (vs git's default 3) in Diff and commit diffs.
    ./paseo-diff-context.patch
    # Show the full commit message when viewing a single commit: pinned
    # subject, then author, date, sha, and body scrolling w/ the diff.
    ./paseo-commit-message.patch
    # Compile built-in plugins during the build. Runtime only reads artifacts
    # and never needs esbuild or TypeScript in its dependency closure.
    ./paseo-precompile-plugins.patch
    # Disable provider CLI release update checks and in-place self-updaters;
    # provider binaries are managed declaratively by Nix.
    ./paseo-disable-provider-updates.patch
  ];

  # Upstream builds w/ `--ignore-scripts`, so the root postinstall never
  # applies `patches/*.patch` to node_modules. W/o the @gorhom/bottom-sheet
  # patch, the web UI crashes w/ React error #130 when opening a chat.
  # https://github.com/getpaseo/paseo/issues/7673
  preBuild = (prevAttrs.preBuild or "") + ''
    npm run postinstall
  '';

  # Keep upstream's sources and build scripts intact. Specialize only the
  # packaged esbuild-backed compiler module after all build-time compilation
  # has finished. Upstream's compiler worker then loads artifacts instead.
  postBuild = (prevAttrs.postBuild or "") + ''
    node packages/server/scripts/precompile-builtin-plugins.mjs
    cp packages/server/scripts/plugin-compiler-runtime.mjs \
      packages/server/dist/server/server/plugins/compiler-build.js
  '';

  # nft follows OpenCode's source-only compiler fallback, although packaged
  # bridge.js requires a prebuilt artifact. No compiler belongs in the output.
  postInstall = (prevAttrs.postInstall or "") + ''
    find "$out/lib/paseo" \
      \( -path '*/node_modules/esbuild' -o -path '*/node_modules/@esbuild' \
        -o -path '*/node_modules/typescript' \) \
      -prune -exec rm -rf {} +
  '';

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
