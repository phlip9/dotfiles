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
    # (nixpkgs' custom patchPhase ignores `patches`)
    patchPhase = ''
      patch -p1 < ${./ebpf-keep-probes-alive.patch}
    ''
    + prev.patchPhase;
  }
)
