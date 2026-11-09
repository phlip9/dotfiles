# Grafana Alloy, bumped ahead of nixpkgs to the 1.22 release candidate.
#
# `pyroscope.ebpf` symbolizes Go frames w/ the engine's Go pclntab parser.
# 1.21.x pins a grafana/opentelemetry-ebpf-profiler fork rev that rejects
# go1.27 binaries ("unsupported Go version go1.27.3 (need >= 1.13 and <=
# 1.26)"), so every Go service on sauna (VictoriaMetrics, Grafana,
# Pyroscope, ...) profiles w/o Go frames. 1.22.0-rc.0 pins fork rev
# 01c4996, which accepts go1.27. Drop this once nixpkgs ships >= 1.22.
{
  fetchFromGitHub,
  fetchNpmDeps,
  grafana-alloy,
  nix-update-script,
}:

# Beyla (`beyla.ebpf`) is a separate prebuilt binary, pinned per Alloy
# release, that Alloy embeds + execs. We don't use it; skip the download.
(grafana-alloy.override { withBeyla = false; }).overrideAttrs (
  finalAttrs: prev: {
    version = "1.22.0-rc.0";

    src = fetchFromGitHub {
      owner = "grafana";
      repo = "alloy";
      tag = "v${finalAttrs.version}";
      hash = "sha256-AwnigngSqNSpKyFjWKV6+S3ZhJkycdrdRx11RAvbAJU=";
    };

    # Web UI, embedded in the binary (`embedalloyui`)
    npmDeps = fetchNpmDeps {
      src = "${finalAttrs.src}/internal/web/ui";
      hash = "sha256-s5vbrl83slJ1yTGK3ICQUirZ5nJ1XhX8Ki6DaeahJQM=";
    };

    vendorHash = "sha256-CBLfxNm85Ah6gXHBtgk5tgEozd0fAUjUClv9Ic2AvtM=";

    # The inherited updater assumes a nixpkgs checkout and updates Beyla.
    # Track release candidates here without the unused Beyla artifacts.
    passthru = prev.passthru // {
      updateScript = nix-update-script {
        extraArgs = [ "--version=unstable" ];
      };
    };

    # `pyroscope.ebpf` only keeps its off-CPU probe in a local var, and the
    # engine's tracer doesn't keep it either (not a trace handler). So the
    # probe's BPF links become unreachable and cilium/ebpf closes them on
    # the next GC: a few off-CPU profiles after startup, then silence, while
    # the component stays healthy. The patch keeps the probes alive until
    # the component stops. Drop once fixed upstream:
    # <https://github.com/grafana/alloy/issues/7675>
    # Regression test: nixos/tests/o11y-profiling-ebpf.nix
    #
    # `pyroscope.ebpf` looks up each pid's labels when it flushes, up to one
    # collect interval after the samples were taken, in a pid map that each
    # discovery refresh replaces. So the last samples of every process that
    # exits before the next flush, but after a refresh, lose their labels
    # and land in `service_name="ebpf/unspecified"`, w/ processes younger
    # than one refresh. Together ~25% of sauna's CPU samples (nix builds:
    # rustc, node, cc1, ...). A shorter refresh only fixes the young ones,
    # it loses more exited ones. The patch keeps an exited pid's labels for
    # 2 report intervals (not w/ `targets_only = true`). Unfixed upstream
    # as of main 5c7b2a1. Regression test:
    # nixos/tests/o11y-profiling-ebpf.nix. The patch's Go unit tests don't
    # run here (the build only tests the `collector` module); run them in
    # a patched source tree: `go test ./internal/component/pyroscope/ebpf/...`
    #
    # `pyroscope.ebpf` builds + pushes one profile per (labels, pid) per
    # collect interval, one push each, 32 at once, all within one collect
    # interval. A push takes ~0.45s (Pyroscope acks after its next 500ms
    # segment flush). Nix builds' short-lived pids fan out to ~600-850
    # pushes per 15s window on sauna; under load the tail misses the
    # deadline and is dropped. W/ `pid_label = false` the per-pid profiles
    # carry nothing that Pyroscope keeps apart. The patch adds
    # `per_pid_profile` (default true = upstream): false builds one profile
    # per labels from all pids' samples, w/o `__process_pid__`. Upstream's
    # builder already has a `PerPIDProfile` option, hardcoded to true and
    # moot b/c the reporter builds each pid's profile separately. Not
    # upstream as of main 5c7b2a1. Unit test in the patch; regression
    # test: nixos/tests/o11y-profiling-ebpf.nix
    #
    # (nixpkgs' custom patchPhase ignores `patches`)
    patchPhase = ''
      patch -p1 < ${./ebpf-keep-probes-alive.patch}
      patch -p1 < ${./ebpf-keep-exited-targets.patch}
      patch -p1 < ${./ebpf-per-pid-profile.patch}
    ''
    + prev.patchPhase;
  }
)
