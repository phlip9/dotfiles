# setup perf for convenient ad-hoc CPU profiling with kernel symbols
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.phlip9-perf;

  # security.wrappers expects an ELF target. Preserve perf's existing package
  # wrapper (Python/objdump PATH setup) behind a standard binary launcher.
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
      description = "Trusted users allowed to run perf with CAP_SYSLOG.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    # Install available split DWARF outputs. This does not rebuild packages
    # that omit debug info or cover arbitrary local development binaries.
    environment.enableDebugInfo = lib.mkIf cfg.enableDebugInfo true;

    # Per-process kernel sampling remains subject to normal target access
    # checks. Keep kernel addresses hidden from unrelated service accounts.
    boot.kernel.sysctl = {
      "kernel.perf_event_paranoid" = 1;
      "kernel.kptr_restrict" = 1;
    };
    users.groups.perf.members = cfg.users;

    # SYSLOG is needed during recording too: unprivileged perf omits kernel
    # map metadata that a privileged reader alone did not recover. Members
    # are trusted operators (phlip9 already has passwordless sudo); the cap
    # also permits kernel-log operations. Other accounts keep kptr filtering.
    #
    # NixOS forwards caps via the ambient set. Launched workloads retain the
    # caller's UID but inherit SYSLOG; attaching leaves target creds intact.
    # No PERFMON: cross-UID and CPU-wide profiling remain restricted.
    security.wrappers.perf = {
      source = lib.getExe perfWithSymbols;
      owner = "root";
      group = "perf";
      permissions = "u=rx,g=rx,o=";
      capabilities = "cap_syslog=ep";
    };
  };
}
