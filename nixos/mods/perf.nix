# Ad-hoc per-process CPU profiling w/ kernel symbols for trusted users.
#
# - Installs `perf` + optional split DWARF (`enableDebugInfo`)
# - Grants `perf` group members a `CAP_SYSLOG`-wrapped `perf` (kernel symbols
#   stay hidden from other accounts via `kptr_restrict=1`)
# - Omits `CAP_PERFMON` so cross-UID and CPU-wide profiling stay restricted
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.phlip9-perf;

  # security.wrappers requires an ELF binary; wrap perf's shell wrapper behind
  # a binary launcher to keep its Python/objdump PATH intact.
  perfWithSymbols =
    pkgs.runCommand "perf-with-symbols"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        meta.mainProgram = "perf";
      }
      ''
        makeWrapper ${lib.getExe cfg.package} "$out/bin/perf"
      '';
in
{
  options.programs.phlip9-perf = {
    enable = lib.mkEnableOption "development perf tools";
    package = lib.mkPackageOption pkgs "perf" { };
    enableDebugInfo = lib.mkEnableOption "available debug outputs";
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Trusted users allowed to run perf w/ CAP_SYSLOG.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    # Installs existing split DWARF outputs (won't rebuild pkgs w/o debug info).
    environment.enableDebugInfo = lib.mkIf cfg.enableDebugInfo true;

    # Allow per-process kernel sampling while keeping kernel addrs hidden from
    # unprivileged accounts.
    boot.kernel.sysctl = {
      "kernel.perf_event_paranoid" = 1;
      "kernel.kptr_restrict" = 1;
    };
    users.groups.perf.members = cfg.users;

    # CAP_SYSLOG is required at record time (unprivileged record omits kernel
    # map metadata a privileged report can't recover). NixOS forwards caps via
    # the ambient set, so launched cmds inherit CAP_SYSLOG (attaching via -p
    # leaves target creds intact).
    security.wrappers.perf = {
      source = lib.getExe perfWithSymbols;
      owner = "root";
      group = "perf";
      permissions = "u=rx,g=rx,o=";
      capabilities = "cap_syslog=ep";
    };
  };
}
