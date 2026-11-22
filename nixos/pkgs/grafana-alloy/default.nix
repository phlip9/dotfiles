# Package Grafana Alloy for whole-host profiling on sauna.
#
# Pin 1.22.0-rc.0 for Go 1.27 frame symbolization. Alloy 1.21's profiler
# rejects Go 1.27 pclntabs. Drop the pin once nixpkgs ships a compatible build.
#
# The profiling patches preserve labels across process exits, bound profile
# size, and batch pushes to Pyroscope.
# see: nixos/mods/o11y/collector/alloy.nix
{
  fetchFromGitHub,
  fetchNpmDeps,
  grafana-alloy,
  lib,
  nix-update-script,
}:

# Disable the embedded Beyla binary to skip its release-specific download.
(grafana-alloy.override { withBeyla = false; }).overrideAttrs (
  finalAttrs: prev: {
    version = "1.22.0-rc.0";

    src = fetchFromGitHub {
      owner = "grafana";
      repo = "alloy";
      tag = "v${finalAttrs.version}";
      hash = "sha256-AwnigngSqNSpKyFjWKV6+S3ZhJkycdrdRx11RAvbAJU=";
    };

    npmDeps = fetchNpmDeps {
      src = "${finalAttrs.src}/internal/web/ui";
      hash = "sha256-s5vbrl83slJ1yTGK3ICQUirZ5nJ1XhX8Ki6DaeahJQM=";
    };

    vendorHash = "sha256-CBLfxNm85Ah6gXHBtgk5tgEozd0fAUjUClv9Ic2AvtM=";

    # Track release candidates. The inherited updater assumes a nixpkgs
    # checkout and refreshes Beyla artifacts.
    passthru = prev.passthru // {
      updateScript = nix-update-script {
        extraArgs = [ "--version=unstable" ];
      };
    };

    # Apply profiling patches before nixpkgs' custom phase, which ignores
    # the standard patches attribute.
    # see: nixos/tests/o11y-profiling-ebpf.nix
    # The package builds from collector/. Run patch unit tests separately w/
    # `go test ./internal/component/pyroscope/ebpf/...`.
    patchPhase =
      let
        patchFiles = [
          # Keep probes alive. GC can close off-CPU BPF links while Alloy still
          # reports healthy. Drop the patch once the upstream fix ships.
          # see: https://github.com/grafana/alloy/issues/7675
          ./ebpf-keep-probes-alive.patch

          # Retain exited targets for two report intervals w/ targets_only
          # disabled. Alloy resolves labels at flush. On sauna, ~25% of CPU
          # samples landed in ebpf/unspecified from exited or undiscovered PIDs.
          ./ebpf-keep-exited-targets.patch

          # Aggregate by label set w/ per_pid_profile = false. Per-PID fan-out
          # during Nix builds pushed requests past the collect deadline.
          ./ebpf-per-pid-profile.patch

          # Include source file and frame kind in the pprof location key.
          # Merged profiles can conflate interpreter frames across files.
          ./ebpf-location-source-file.patch

          # Compact equal sample rows and split oversized profiles. Pyroscope
          # validates size before merging rows. Defaults are 8,000 samples and
          # 1 MiB uncompressed per profile.
          ./ebpf-bound-profiles.patch

          # Batch an interval when all receivers support it. Pyroscope acks on
          # segment flush, so separate requests add latency. Split batches at
          # a soft 4 MiB target. Each request retries as a unit.
          ./pyroscope-batch-push.patch

          # Opt-in hooks let VM tests order manual flushes around discovery
          # updates and pending samples.
          ./ebpf-test-hooks.patch
        ];
      in
      lib.concatMapStrings (patch: "patch -p1 < ${patch}\n") patchFiles
      + prev.patchPhase;
  }
)
