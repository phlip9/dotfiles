# Wrapped sops with clean nvim as EDITOR.
#
# When editing secrets with sops, we want a minimal editor without plugins
# (especially AI plugins like Copilot) to avoid leaking secrets.
#
# This wrapper sets EDITOR to clean nvim (--clean --noplugin -n).
{
  lib,
  makeBinaryWrapper,
  neovim-unwrapped,
  runCommandLocal,
  sops,
}:
let
  # Clean nvim invocation suitable for editing secrets.
  # --clean: skip user config + plugins
  # --noplugin: extra insurance against plugins
  # -n: no swap file (don't leave secrets on disk)
  cleanNvim = "${lib.getExe neovim-unwrapped} --clean --noplugin -n";
in
runCommandLocal "sops-secure-${sops.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta = sops.meta // {
      description = "sops wrapped with clean nvim (no plugins)";
    };
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${lib.getExe sops} $out/bin/sops \
      --set EDITOR "${cleanNvim}"

    # Link all non-bin directories (share/, etc.) for completions and extras
    for dir in ${sops}/*/; do
      name=$(basename "$dir")
      [[ "$name" != "bin" ]] && ln -s "$dir" "$out/$name"
    done
  ''
