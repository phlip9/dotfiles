# NixOS container test for phlip9-o11y profiling (Pyroscope).
#
# Single container w/ the o11y module + profiling enabled. The test pushes a
# fixture CPU profile w/ `profilecli upload`, over the same Connect `Push` API
# that collectors use, then reads it back through Grafana.
#
# Verifies:
# - Pyroscope starts (v2 storage, loopback-only rings) + turns ready
# - the effective config: v2 storage, default retention
# - vmagent scrapes Pyroscope into VictoriaMetrics
# - Grafana's Pyroscope datasource: provisioned, plugin backend healthy
# - a pushed profile reads back through the datasource proxy (Drilldown,
#   mcp-grafana, profilecli) and `/api/ds/query` (panels, Explore)
let
  # Labels + profile type of the fixture profile
  service = "o11y-test";
  profileType = "process_cpu:cpu:nanoseconds:cpu:nanoseconds";
  # A function in the fixture's stacks
  hotFn = "main.slowFunction";
in
{
  name = "o11y-profiling";

  globalTimeout = 300;

  containers.machine =
    { lib, pkgs, ... }:
    let
      secret = name: text: pkgs.writeText name "${text}\n";
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      # Go CPU profile w/ ~50 samples, from Pyroscope's own test data. Copied
      # out so only this file, not Pyroscope's source, enters the closure.
      environment.etc."o11y-test/cpu.pb.gz".source =
        pkgs.runCommand "pyroscope-cpu.pb.gz" { }
          ''
            cp ${pkgs.pyroscope.src}/pkg/og/convert/pprof/testdata/cpu.pb.gz $out
          '';

      services.phlip9-o11y = {
        server = {
          enable = true;
          retentionPeriod = "1d";
          grafana = {
            adminPasswordFile = secret "gf-admin-pwd" "gf-admin-testpwd";
            secretKeyFile = secret "gf-secret-key" "test-secret-key-0123456789";
            secretsManagerKeyFile = secret "gf-sm-key" "test-sm-key-0123456789";
          };
          profiling.enable = true;
        };
        # No Alloy (`collector.profiling`): eBPF needs a VM, see
        # ./o11y-profiling-ebpf.nix
        collector.enable = true;
      };

      # Unused here: node metrics, ssh, pyroscope-du (blocks multi-user.target)
      services.prometheus.exporters.node.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;
      systemd.services.pyroscope-du.enable = lib.mkForce false;
      systemd.timers.pyroscope-du.enable = lib.mkForce false;

      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      # Grafana's startup chatter. Keep warnings + errors only.
      services.phlip9-o11y.server.grafana.logFilters = [
        "migrator:warn"
        "resource-migrator:warn"
        "secret-migrator:warn"
        "unifiedstorage-migrator:warn"
        "storage.unified.migrations:warn"
        "storage.unified.migration_runner.folders-dashboards:warn"
        "storage.unified.migration_runner.playlists:warn"
        "storage.unified.migration_runner.shorturls:warn"
        "storage.unified.migrator:warn"
        "backgroundsvcs.managerAdapter:warn"
        "grafana-apiserver:warn"
        "bleve-backend:warn"
      ];
    };

  testScript = ''
    import json
    import shlex
    import time

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        UP_TIMEOUT,
        dump_evidence,
        wait_fast,
        wait_for_http,
        wait_for_port,
    )
    from testlib.o11y import PYRO_URL, VM_URL, wait_for_vm_labels

    GF_URL = "http://127.0.0.1:3000"
    GF_CURL = f"{CURL} --fail-with-body -u admin:gf-admin-testpwd"

    SERVICE = "${service}"
    PROFILE_TYPE = "${profileType}"
    HOT_FN = "${hotFn}"
    SELECTOR = f'{{service_name="{SERVICE}"}}'

    # Pyroscope's ports: http, grpc, metastore raft, memberlist
    PYRO_PORTS = {4040, 9095, 9099, 7946}

    # POST a JSON body through Grafana, return the parsed response.
    def gf_post(path: str, body: dict) -> dict:
        data = shlex.quote(json.dumps(body))
        out = machine.succeed(
            f"{GF_CURL} -H 'Content-Type: application/json' "
            f"--data-binary {data} {GF_URL}{path}",
            timeout=CMD_TIMEOUT,
        )
        return json.loads(out)

    up_query = shlex.quote('up{job="pyroscope"}')
    EVIDENCE = [(
        machine,
        [
            "journalctl --no-pager -o cat -u pyroscope | tail -n 100",
            "journalctl --no-pager -o cat -u victoriametrics | tail -n 30",
            "journalctl --no-pager -o cat -u vmagent | tail -n 30",
            "journalctl --no-pager -o cat -u grafana | tail -n 50",
            f"{CURL} {PYRO_URL}/ready",
            f"{CURL} {PYRO_URL}/api/v1/status/config/diff",
            f"{CURL} {VM_URL}/api/v1/query --data-urlencode query={up_query}",
            "ss -Hltunp",
        ],
    )]

    machine.start()
    try:
        with subtest("Pyroscope starts + turns ready"):
            machine.wait_for_unit("pyroscope.service", timeout=UP_TIMEOUT)
            wait_for_http(machine, f"{PYRO_URL}/ready")

        # Regression guard: Pyroscope has no authn, and several of its
        # listeners default to all interfaces (grpc, memberlist).
        with subtest("Pyroscope only listens on loopback"):
            out = machine.succeed("ss -Hltun", timeout=CMD_TIMEOUT)
            # `ss` local address column: `127.0.0.1:4040`, `[::1]:9099`, ...
            listeners = [line.split()[4] for line in out.splitlines()]
            seen = set()
            for local in listeners:
                addr, _, port = local.rpartition(":")
                if int(port) not in PYRO_PORTS:
                    continue
                seen.add(int(port))
                assert addr in {"127.0.0.1", "[::1]"}, (local, out)
            # Prove each listener exists before trusting the check above.
            assert seen == PYRO_PORTS, (seen, out)

        with subtest("Pyroscope config: v2 storage, default retention"):
            conf = machine.succeed(
                f"{CURL} -f {PYRO_URL}/api/v1/status/config",
                timeout=CMD_TIMEOUT,
            )
            lines = {line.strip() for line in conf.splitlines()}
            assert "architecture_storage: v2" in lines, conf
            assert "retention_period: 30d" in lines, conf

        # Before the Grafana subtests: its segment flush + indexing overlap
        # w/ Grafana's startup.
        with subtest("push a profile"):
            # Pyroscope rejects profiles older than ~1h. The fixture is from
            # 2021, so stamp it w/ the current time.
            push_ms = int(time.time() * 1000)
            machine.succeed(
                f"profilecli upload --url {PYRO_URL} --override-timestamp "
                f"--extra-labels service_name={SERVICE} /etc/o11y-test/cpu.pb.gz",
                timeout=CMD_TIMEOUT,
            )
            start_ms = push_ms - 60_000
            end_ms = push_ms + 600_000

        with subtest("vmagent scrapes Pyroscope into VictoriaMetrics"):
            wait_for_vm_labels(machine, 'up{job="pyroscope"} == 1')

        with subtest("Grafana Pyroscope datasource + plugin backend"):
            machine.wait_for_unit("grafana.service", timeout=UP_TIMEOUT)
            wait_for_port(machine, 3000)
            ds = json.loads(machine.succeed(
                f"{GF_CURL} {GF_URL}/api/datasources/uid/pyroscope",
                timeout=CMD_TIMEOUT,
            ))
            assert ds["type"] == "grafana-pyroscope-datasource", ds
            assert ds["url"] == PYRO_URL, ds
            assert ds["isDefault"] is False, ds
            # Runs the plugin's Go backend, which queries Pyroscope.
            health = json.loads(machine.succeed(
                f"{GF_CURL} {GF_URL}/api/datasources/uid/pyroscope/health",
                timeout=CMD_TIMEOUT,
            ))
            assert health["status"] == "OK", health

        with subtest("query the profile back through Grafana"):
            # The Connect API, via the datasource proxy, like Profiles
            # Drilldown. The profile is queryable once the segment writer
            # flushed it + the metastore indexed it.
            def merged_names() -> list[str]:
                resp = gf_post(
                    "/api/datasources/proxy/uid/pyroscope"
                    "/querier.v1.QuerierService/SelectMergeStacktraces",
                    {
                        "profileTypeID": PROFILE_TYPE,
                        "labelSelector": SELECTOR,
                        "start": start_ms,
                        "end": end_ms,
                    },
                )
                return resp.get("flamegraph", {}).get("names", [])

            wait_fast(
                lambda: HOT_FN in merged_names(), f"profile w/ {HOT_FN}"
            )

            # Grafana's backend query path, like flame graph panels + Explore
            resp = gf_post("/api/ds/query", {
                "from": str(start_ms),
                "to": str(end_ms),
                "queries": [{
                    "refId": "A",
                    "datasource": {"uid": "pyroscope"},
                    "queryType": "profile",
                    "profileTypeId": PROFILE_TYPE,
                    "labelSelector": SELECTOR,
                    "groupBy": [],
                    "maxNodes": 16384,
                }],
            })
            result = resp["results"]["A"]
            assert "error" not in result, result
            assert HOT_FN in json.dumps(result["frames"]), result

        # Not an assertion: resource numbers for tuning.
        print(machine.succeed(
            "systemctl show pyroscope -p CPUUsageNSec; "
            "grep -E '^Vm(RSS|HWM)' "
            "/proc/$(systemctl show pyroscope -p MainPID --value)/status; "
            "du -sh /var/lib/pyroscope/",
            timeout=CMD_TIMEOUT,
        ))
    except Exception:
        dump_evidence(EVIDENCE)
        raise
  '';
}
