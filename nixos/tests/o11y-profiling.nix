# Exercise the phlip9-o11y profiling stack in one NixOS container.
#
#   profilecli --Connect Push--> Pyroscope <--queries-- Grafana
#
# - Pyroscope: readiness, loopback listeners, v2 storage, and 30d retention.
# - Metrics: vmagent scrapes Pyroscope into VictoriaMetrics.
# - Grafana: datasource provisioning, health, and profile readback.
#
# Upload a CPU fixture through the same Push API as Alloy. The eBPF
# collector runs in a separate VM test.
# see: nixos/tests/o11y-profiling-ebpf.nix
let
  # Profile selector values and a known stack frame for readback.
  service = "o11y-test";
  profileType = "process_cpu:cpu:nanoseconds:cpu:nanoseconds";
  hotFn = "main.slowFunction";
in
{
  name = "o11y-profiling";

  globalTimeout = 300;

  containers.machine =
    { lib, pkgs, ... }:
    let
      # Match the newline in production sops secret files.
      secret = name: text: pkgs.writeText name "${text}\n";
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      # Copy the Go CPU fixture to keep Pyroscope's source out of the guest.
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
        collector.enable = true;
      };

      services.prometheus.exporters.node.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      # Skip the disk usage scan so it can't delay multi-user.target.
      systemd.services.pyroscope-du.enable = lib.mkForce false;
      systemd.timers.pyroscope-du.enable = lib.mkForce false;

      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      # Suppress routine migration, startup, and index build logs.
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

    # Expected listeners for HTTP, gRPC, metastore Raft, and memberlist.
    PYRO_PORTS = {4040, 9095, 9099, 7946}

    # POST to Grafana and decode the JSON response.
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
        # --- Pyroscope startup and config --- #

        with subtest("Pyroscope becomes ready"):
            machine.wait_for_unit("pyroscope.service", timeout=UP_TIMEOUT)
            wait_for_http(machine, f"{PYRO_URL}/ready")

        with subtest("Pyroscope binds all expected ports to loopback"):
            # Loopback keeps unauthenticated listeners local.
            # see: nixos/mods/o11y/server/pyroscope.nix
            out = machine.succeed("ss -Hltun", timeout=CMD_TIMEOUT)
            # The local address column includes the port and brackets IPv6.
            listeners = [line.split()[4] for line in out.splitlines()]
            seen = set()
            for local in listeners:
                addr, _, port = local.rpartition(":")
                if int(port) not in PYRO_PORTS:
                    continue
                seen.add(int(port))
                assert addr in {"127.0.0.1", "[::1]"}, (local, out)
            # Require every port so missing listeners fail the check too.
            assert seen == PYRO_PORTS, (seen, out)

        with subtest("Pyroscope uses v2 storage and default retention"):
            conf = machine.succeed(
                f"{CURL} -f {PYRO_URL}/api/v1/status/config",
                timeout=CMD_TIMEOUT,
            )
            lines = {line.strip() for line in conf.splitlines()}
            assert "architecture_storage: v2" in lines, conf
            assert "retention_period: 30d" in lines, conf

        # --- Profile ingest and metrics --- #

        with subtest("profilecli uploads a CPU profile"):
            # Upload early to overlap indexing w/ scrape and datasource checks.
            # Use a fresh timestamp to pass Pyroscope's sample age limit.
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

        # --- Grafana datasource --- #

        with subtest("Grafana provisions a healthy Pyroscope datasource"):
            machine.wait_for_unit("grafana.service", timeout=UP_TIMEOUT)
            wait_for_port(machine, 3000)
            ds = json.loads(machine.succeed(
                f"{GF_CURL} {GF_URL}/api/datasources/uid/pyroscope",
                timeout=CMD_TIMEOUT,
            ))
            assert ds["type"] == "grafana-pyroscope-datasource", ds
            assert ds["url"] == PYRO_URL, ds
            assert ds["isDefault"] is False, ds

            # The health endpoint checks the plugin's connection to Pyroscope.
            health = json.loads(machine.succeed(
                f"{GF_CURL} {GF_URL}/api/datasources/uid/pyroscope/health",
                timeout=CMD_TIMEOUT,
            ))
            assert health["status"] == "OK", health

        with subtest("Grafana reads the profile via proxy and backend queries"):
            # Read stack names via the Connect proxy used by Profiles Drilldown.
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

            # Readback waits on the segment flush and metastore indexing.
            wait_fast(
                lambda: HOT_FN in merged_names(),
                f"profile stack containing {HOT_FN}",
            )

            # Exercise the backend query path used by flame graph panels.
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

        # Log Pyroscope's CPU, memory, and disk use for tuning.
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
