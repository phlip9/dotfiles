{
  fetchurl,
  lib,
  openssl,
  stdenv,
}:
let
  version = "0.45.0";

  sources = {
    x86_64-linux = rec {
      target = "x86_64-unknown-linux-gnu";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-Af4/iKMyaKCyEC7ehO5laYCxOWRH30VkVaI+8EXL4Rg=";
    };
    aarch64-darwin = rec {
      target = "aarch64-apple-darwin";
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-${target}.tar.gz";
      hash = "sha256-zdZt2ej30ENbU0vfuoT5gi3AbtRQ9p5tIf9lPU6fTjY=";
    };
  };

  source = sources.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp codex-${source.target} $out/bin/codex

    runHook postInstall
  '';

  fixupPhase = lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf --set-rpath "${
      lib.makeLibraryPath [
        stdenv.cc.cc
        stdenv.cc.libc
        openssl
      ]
    }" "$out/bin/codex"
    patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$out/bin/codex"
  '';
}
# TODO(phlip9): build from source when nixpkgs gets newer rustc
# {
#   fetchFromGitHub,
#   openssl,
#   pkg-config,
#   rustPlatform,
#   writeText,
# }:
# rustPlatform.buildRustPackage rec {
#   pname = "codex";
#   version = "0.45.0";
#
#   src = fetchFromGitHub {
#     owner = "openai";
#     repo = "codex";
#     tag = "rust-v${version}";
#     hash = "sha256-HRVfUK+ZH/Q2xEQ16wboA56q9Ia3Xx5LpdqKSpjr5hI=";
#   };
#
#   sourceRoot = "${src.name}/codex-rs";
#
#   patches = [
#     (writeText "compile-with-older-rustc.patch" ''
#       --- a/apply-patch/src/lib.rs
#       +++ b/apply-patch/src/lib.rs
#       @@ -576,12 +576,12 @@ fn apply_hunks_to_files(hunks: &[Hunk]) -> anyhow::Result<AffectedPaths> {
#            for hunk in hunks {
#                match hunk {
#                    Hunk::AddFile { path, contents } => {
#       -                if let Some(parent) = path.parent()
#       -                    && !parent.as_os_str().is_empty()
#       -                {
#       -                    std::fs::create_dir_all(parent).with_context(|| {
#       -                        format!("Failed to create parent directories for {}", path.display())
#       -                    })?;
#       +                if let Some(parent) = path.parent() {
#       +                    if !parent.as_os_str().is_empty() {
#       +                        std::fs::create_dir_all(parent).with_context(|| {
#       +                            format!("Failed to create parent directories for {}", path.display())
#       +                        })?;
#       +                    }
#                        }
#                        std::fs::write(path, contents)
#                            .with_context(|| format!("Failed to write file {}", path.display()))?;
#       @@ -600,12 +600,12 @@ fn apply_hunks_to_files(hunks: &[Hunk]) -> anyhow::Result<AffectedPaths> {
#                        let AppliedPatch { new_contents, .. } =
#                            derive_new_contents_from_chunks(path, chunks)?;
#                        if let Some(dest) = move_path {
#       -                    if let Some(parent) = dest.parent()
#       -                        && !parent.as_os_str().is_empty()
#       -                    {
#       -                        std::fs::create_dir_all(parent).with_context(|| {
#       -                            format!("Failed to create parent directories for {}", dest.display())
#       -                        })?;
#       +                    if let Some(parent) = dest.parent() {
#       +                        if !parent.as_os_str().is_empty() {
#       +                            std::fs::create_dir_all(parent).with_context(|| {
#       +                                format!("Failed to create parent directories for {}", dest.display())
#       +                            })?;
#       +                        }
#                            }
#                            std::fs::write(dest, new_contents)
#                                .with_context(|| format!("Failed to write file {}", dest.display()))?;
#       --- a/protocol/src/protocol.rs
#       +++ b/protocol/src/protocol.rs
#       @@ -360,11 +360,12 @@ impl SandboxPolicy {
#                        // Linux or Windows, but supporting it here gives users a way to
#                        // provide the model with their own temporary directory without
#                        // having to hardcode it in the config.
#       -                if !exclude_tmpdir_env_var
#       -                    && let Some(tmpdir) = std::env::var_os("TMPDIR")
#       -                    && !tmpdir.is_empty()
#       -                {
#       -                    roots.push(PathBuf::from(tmpdir));
#       +                if !exclude_tmpdir_env_var {
#       +                    if let Some(tmpdir) = std::env::var_os("TMPDIR") {
#       +                        if !tmpdir.is_empty() {
#       +                            roots.push(PathBuf::from(tmpdir));
#       +                        }
#       +                    }
#                        }
#
#                        // For each root, compute subpaths that should remain read-only.
#     '')
#   ];
#
#   cargoHash = "sha256-7uO7I84kthMh4UQUioW7gf1E0IB+9ov/tDvXdiCdK2s=";
#
#   cargoBuildFlags = "-p codex-cli --bin codex";
#
#   nativeBuildInputs = [pkg-config];
#
#   buildInputs = [openssl];
# }
