# NixOS container test for phlip9-o11y alerting (vmalert + Alertmanager).
#
# Single container w/ the o11y module + alerting enabled. A local HTTP sink
# stands in for Discord and healthchecks.io: the module's secret URL files
# point at it, and it logs every request. Test rules fire on metrics the
# test pushes into VictoriaMetrics, so each alert fires on demand.
#
# Verifies:
# - vmalert loads + evaluates every rule group w/o errors
# - a page reaches Discord in full + as an @mention (envsubst'ed user id),
#   then its resolve w/o one; a warn never gets one
# - sauna's inhibit rules hold back a symptom while its cause fires
# - Watchdog pings the healthchecks sink, never Discord
# - healthchecks-host-ping pings, or logs why + skips it when vmalert is down
# - Grafana's Alertmanager datasource
#
# Rule semantics + routing are unit tested offline in
# `nixosTests.o11y-alerting-unit`. This test covers the plumbing.
let
  # Alert sink: Discord + healthchecks.io stand-in, see `alertSink`
  sinkPort = 8099;
  sinkUrl = "http://127.0.0.1:${toString sinkPort}";
  sinkLog = "/var/lib/alert-sink/requests.jsonl";
in
{
  name = "o11y-alerting";

  globalTimeout = 300;

  containers.machine =
    {
      lib,
      phlipPkgs,
      pkgs,
      ...
    }:
    let
      # Secrets, w/ trailing newlines like sops secret files.
      secret = name: text: pkgs.writeText name "${text}\n";
      # Secret URL file pointing at `<sink>/<path>`
      sinkUrlFile = path: secret "sink-url-${path}" "${sinkUrl}/${path}";

      # Stand-in for Discord + healthchecks.io: appends every request as a
      # JSON line `{method, path, body}` to a log file, replies 200.
      alertSink = phlipPkgs.writeTypedPython3Bin "alert-sink" { } ''
        import json
        import sys
        import threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from pathlib import Path

        LOG = Path(sys.argv[2])
        LOCK = threading.Lock()


        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def _record(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length).decode("utf-8", "replace")
                line = json.dumps(
                    {"method": self.command, "path": self.path, "body": body}
                )
                with LOCK, LOG.open("a", encoding="utf-8") as log:
                    log.write(line + "\n")
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

            do_GET = do_POST = _record


        def main() -> None:
            LOG.touch()
            addr = ("127.0.0.1", int(sys.argv[1]))
            ThreadingHTTPServer(addr, Handler).serve_forever()


        if __name__ == "__main__":
            main()
      '';

      # Rule that fires while the test pushes `metric` > 0.
      testRule = alert: metric: severity: {
        inherit alert;
        expr = "${metric} > 0";
        labels.severity = severity;
        annotations.summary = metric;
      };
    in
    {
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.phlip9-o11y = {
        enable = true;
        retentionPeriod = "1d";
        grafana = {
          # Links in notifications. Inert w/o nginx.
          domain = "grafana.test";
          adminPasswordFile = secret "gf-admin-pwd" "gf-admin-testpwd";
          secretKeyFile = secret "gf-secret-key" "test-secret-key-0123456789";
          secretsManagerKeyFile = secret "gf-sm-key" "test-sm-key-0123456789";
        };

        alerting = {
          enable = true;
          discordWebhookUrlFile = sinkUrlFile "discord";
          environmentFile = secret "am-env" "DISCORD_USER_ID=12345";
          healthchecksWatchdogPingUrlFile = sinkUrlFile "watchdog";
          healthchecksHostPingUrlFile = sinkUrlFile "host";

          # Test knobs: notify right away.
          groupWait = "0s";
          groupInterval = "1s";
        };
      };

      services.vmalert.instances."".rules.groups = [
        {
          name = "test";
          rules = [
            (testRule "TestPage" "test_page" "page")
            (testRule "TestWarn" "test_warn" "warn")
            # Named after sauna's inhibit rule `PgDown` hides `Nixbot.+`
            (testRule "PgDown" "test_cause" "warn")
            (testRule "NixbotSymptom" "test_symptom" "warn")
          ];
        }
      ];

      # Never night (year 1999), so pages always get their @mention.
      # `configuration` merges shallowly (`//`); mkAfter makes this win.
      services.prometheus.alertmanager.configuration = lib.mkAfter {
        time_intervals = [
          {
            name = "night";
            time_intervals = [ { years = [ "1999" ]; } ];
          }
        ];
      };

      # Evaluate every second, on samples as fresh as possible.
      services.vmalert.instances."".settings = {
        evaluationInterval = "1s";
        "rule.evalDelay" = "0s";
      };
      services.victoriametrics.prometheusConfig.global.scrape_interval = "1s";
      # Queries hide samples younger than `-search.latencyOffset` (30s).
      services.victoriametrics.extraOptions = [ "-search.latencyOffset=0s" ];

      systemd.services.alert-sink = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe alertSink} ${toString sinkPort} ${sinkLog}";
          StateDirectory = "alert-sink";
        };
      };
      # Skip Alertmanager's retry backoff on the first notifications.
      systemd.services.alertmanager = {
        wants = [ "alert-sink.service" ];
        after = [ "alert-sink.service" ];
      };

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
    from typing import Any, Callable, TypeVar

    T = TypeVar("T")

    SINK_LOG = "${sinkLog}"
    VM_URL = "http://127.0.0.1:8428"
    AM_URL = "http://127.0.0.1:9093"
    GF_URL = "http://127.0.0.1:3000"
    # `enforce_domain` redirects requests for any other Host.
    GF_CURL = (
        "curl -sS --fail-with-body -u admin:gf-admin-testpwd "
        "-H 'Host: grafana.test'"
    )
    HOST_PING = "healthchecks-host-ping.service"

    # Requests the sink logged for `path`, oldest first.
    def sink(path: str) -> list[dict[str, Any]]:
        out = machine.succeed(f"cat {SINK_LOG}")
        reqs = [json.loads(line) for line in out.splitlines()]
        return [req for req in reqs if req["path"] == path]

    # Discord webhook payloads: `{content, embeds: [{title, description}]}`
    def discord() -> list[dict[str, Any]]:
        return [json.loads(req["body"]) for req in sink("/discord")]

    # Discord messages w/ this embed title, ex: "FIRING:1 page TestPage"
    def discord_titled(title: str) -> list[dict[str, Any]]:
        return [msg for msg in discord() if msg["embeds"][0]["title"] == title]

    # Poll `fn` (1/s) until it returns something truthy, then return that.
    def wait_for(fn: Callable[[], T], timeout: int = 30) -> T:
        result: list[T] = []

        def check(_last_try: bool) -> bool:
            value = fn()
            if value:
                result.append(value)
            return bool(value)

        retry(check, timeout=dt.timedelta(seconds=timeout))
        return result[0]

    # Push samples (Prometheus text format) into VictoriaMetrics.
    def push(*lines: str) -> None:
        body = shlex.quote("\n".join(lines) + "\n")
        machine.succeed(
            f"printf %s {body} | curl -sSf --data-binary @- "
            f"{VM_URL}/api/v1/import/prometheus"
        )

    # Alerts Alertmanager dropped from group flushes b/c of an inhibition.
    def inhibited() -> float:
        metric = "alertmanager_notifications_suppressed_total"
        out = machine.succeed(f"curl -sSf {AM_URL}/metrics")
        for line in out.splitlines():
            if line.startswith(f'{metric}{{reason="inhibition"}} '):
                return float(line.split()[-1])
        return 0.0

    def dump_evidence() -> None:
        for cmd in [
            "journalctl --no-pager -o cat -u vmalert -u alertmanager "
            f"-u {HOST_PING} -u alert-sink | tail -n 100",
            f"cat {SINK_LOG}",
            f"curl -sS {AM_URL}/api/v2/alerts",
        ]:
            print(f"$ {cmd}\n{machine.execute(cmd)[1]}")

    machine.start()
    try:
        # Real rules evaluate against real (container) metrics, so a broken
        # expression shows up here as a rule error.
        with subtest("services start, vmalert evaluates every rule group"):
            for unit in [
                "victoriametrics.service",
                "alert-sink.service",
                "alertmanager.service",
                "vmalert.service",
            ]:
                machine.wait_for_unit(unit)
            machine.wait_for_open_port(8880)
            machine.wait_for_open_port(9093)

            # Create the test rules' series up front. VM makes new series
            # searchable only every ~10s, new samples of known ones in ~1s.
            push("test_page 0", "test_warn 0", "test_cause 0", "test_symptom 0")

            # All rule groups, once every rule has run, else [].
            def rules_evaluated() -> list[dict[str, Any]]:
                groups = json.loads(machine.succeed(
                    "curl -sSf http://127.0.0.1:8880/api/v1/rules"
                ))["data"]["groups"]
                rules = [rule for group in groups for rule in group["rules"]]
                if any(r["lastEvaluation"].startswith("0001-") for r in rules):
                    return []
                return groups

            groups = wait_for(rules_evaluated)
            names = {group["name"] for group in groups}
            assert {"watchdog", "host", "storage", "test"} <= names, names
            errors = [
                (rule["name"], rule["lastError"])
                for group in groups
                for rule in group["rules"]
                if rule["lastError"]
            ]
            assert not errors, errors

        with subtest("page: full message + @mention, resolve w/o mention"):
            push("test_page 1")
            title = "FIRING:1 page TestPage"
            wait_for(lambda: len(discord_titled(title)) == 2)
            msgs = discord_titled(title)
            assert sorted(m["content"] for m in msgs) == ["", "<@12345>"], msgs
            full = next(m for m in msgs if m["content"] == "")
            desc = full["embeds"][0]["description"]
            assert desc.startswith("- **test_page**\n"), desc
            silence = "(https://grafana.test/alerting/silence/new?"
            assert silence in desc, desc

            push("test_page 0")
            resolved = wait_for(
                lambda: discord_titled("RESOLVED page TestPage")
            )
            assert all(m["content"] == "" for m in resolved), resolved

        with subtest("warn reaches Discord w/o a mention"):
            push("test_warn 1")
            msgs = wait_for(lambda: discord_titled("FIRING:1 warn TestWarn"))
            assert [m["content"] for m in msgs] == [""], msgs

        with subtest("inhibited symptom held back while its cause fires"):
            push("test_cause 1")
            wait_for(lambda: discord_titled("FIRING:1 warn PgDown"))
            before = inhibited()
            push("test_symptom 1")
            # Alertmanager flushed the symptom's group and dropped it.
            wait_for(lambda: inhibited() > before)
            symptom = "FIRING:1 warn NixbotSymptom"
            assert not discord_titled(symptom), discord()
            push("test_cause 0")
            wait_for(lambda: discord_titled(symptom))

        # After the Discord subtests: every delivery above happened while
        # the Watchdog fired.
        with subtest("Watchdog pings healthchecks.io, never Discord"):
            ping = wait_for(lambda: sink("/watchdog"))[0]
            assert ping["method"] == "POST", ping
            payload = json.loads(ping["body"])
            assert payload["status"] == "firing", payload
            assert payload["alerts"][0]["labels"]["alertname"] == "Watchdog"
            msgs = discord()
            assert all("Watchdog" not in json.dumps(m) for m in msgs), msgs

        with subtest("host ping: ping if healthy, else skip it"):
            machine.succeed("systemctl is-active healthchecks-host-ping.timer")
            # Only the runs below. A run the timer already started merges
            # into the first `systemctl start`.
            machine.succeed("systemctl stop healthchecks-host-ping.timer")
            pings = len(sink("/host"))
            machine.succeed(f"systemctl start {HOST_PING}")
            assert len(sink("/host")) == pings + 1, sink("/host")

            # The run succeeds: healthchecks.io's grace period is the signal.
            machine.succeed("systemctl stop vmalert.service")
            machine.succeed(f"systemctl start {HOST_PING}")
            machine.wait_until_succeeds(
                f"journalctl -o cat -u {HOST_PING} "
                "| grep -q 'vmalert: vmalert.service is not active'",
                timeout=dt.timedelta(seconds=10),
            )
            assert len(sink("/host")) == pings + 1, sink("/host")
            machine.succeed("systemctl start vmalert.service")

        with subtest("Grafana Alertmanager datasource"):
            machine.wait_for_unit("grafana.service")
            machine.wait_for_open_port(3000)
            # Grafana's datasource test: GET /api/v2/status through its proxy
            machine.wait_until_succeeds(
                f"{GF_CURL} {GF_URL}/api/datasources/proxy/uid/alertmanager"
                "/api/v2/status | jq -e .cluster",
                timeout=dt.timedelta(seconds=60),
            )
    except Exception:
        dump_evidence()
        raise
  '';
}
