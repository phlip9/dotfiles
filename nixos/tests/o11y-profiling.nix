# NixOS container test for phlip9-o11y profiling (Pyroscope).
#
# Single container w/ the o11y module + profiling enabled. The test pushes a
# fixture CPU profile w/ `profilecli upload`, over the same Connect `Push` API
# that collectors use, then reads it back through Grafana.
#
# Verifies:
# - Pyroscope starts (v2 storage, loopback-only rings) + turns ready
# - the effective config: v2 storage, default retention
# - VictoriaMetrics scrapes Pyroscope
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
        enable = true;
        retentionPeriod = "1d";
        grafana = {
          adminPasswordFile = secret "gf-admin-pwd" "gf-admin-testpwd";
          secretKeyFile = secret "gf-secret-key" "test-secret-key-0123456789";
          secretsManagerKeyFile = secret "gf-sm-key" "test-sm-key-0123456789";
        };
        profiling = {
          enable = true;
          # eBPF needs a VM, see ./o11y-profiling-ebpf.nix
          collector.enable = false;
        };
      };

      # Unused here: node metrics, ssh
      services.prometheus.exporters.node.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      services.victoriametrics.prometheusConfig.global.scrape_interval = "1s";
      # Queries hide samples younger than `-search.latencyOffset` (30s).
      services.victoriametrics.extraOptions = [ "-search.latencyOffset=0s" ];

      # Grafana's startup chatter. Keep warnings + errors only.
      services.grafana.settings.log.filters = lib.concatStringsSep " " [
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
    import datetime as dt
    import json
    import shlex
    import time

    PYRO_URL = "http://127.0.0.1:4040"
    VM_URL = "http://127.0.0.1:8428"
    GF_URL = "http://127.0.0.1:3000"
    # Bound every request, so a hung server fails its step, not the test's
    # globalTimeout, and `dump_evidence` still runs.
    CURL = "curl -sS --connect-timeout 2 --max-time 10"
    GF_CURL = f"{CURL} --fail-with-body -u admin:gf-admin-testpwd"
    # Upper bound for one command, incl. its curl
    CMD_TIMEOUT = dt.timedelta(seconds=15)

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

    def dump_evidence() -> None:
        up_query = shlex.quote('up{job="pyroscope"}')
        for cmd in [
            "journalctl --no-pager -o cat -u pyroscope | tail -n 100",
            "journalctl --no-pager -o cat -u victoriametrics | tail -n 30",
            "journalctl --no-pager -o cat -u grafana | tail -n 50",
            f"{CURL} {PYRO_URL}/ready",
            f"{CURL} {PYRO_URL}/api/v1/status/config/diff",
            f"{CURL} {VM_URL}/api/v1/query --data-urlencode query={up_query}",
            "ss -Hltunp",
        ]:
            _, out = machine.execute(cmd, timeout=CMD_TIMEOUT)
            print(f"$ {cmd}\n{out}")

    machine.start()
    try:
        with subtest("Pyroscope starts + turns ready"):
            machine.wait_for_unit(
                "pyroscope.service", timeout=dt.timedelta(seconds=60)
            )
            machine.wait_until_succeeds(
                f"{CURL} -f {PYRO_URL}/ready",
                timeout=dt.timedelta(seconds=60),
            )

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

        with subtest("VictoriaMetrics scrapes Pyroscope"):
            query = shlex.quote('up{job="pyroscope"}')
            machine.wait_until_succeeds(
                f"{CURL} -f {VM_URL}/api/v1/query --data-urlencode query={query} "
                "| jq -e '.data.result[0].value[1] == \"1\"'",
                timeout=dt.timedelta(seconds=30),
            )

        with subtest("Grafana Pyroscope datasource + plugin backend"):
            machine.wait_for_unit(
                "grafana.service", timeout=dt.timedelta(seconds=60)
            )
            machine.wait_for_open_port(3000, timeout=dt.timedelta(seconds=30))
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

        with subtest("push a profile, query it back through Grafana"):
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

            def has_hot_fn(_last_try: bool) -> bool:
                return HOT_FN in merged_names()

            retry(has_hot_fn, timeout=dt.timedelta(seconds=30))

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
        dump_evidence()
        raise
  '';
}
