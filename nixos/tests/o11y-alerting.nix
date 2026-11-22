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
      imports = [ ./lib/victoriametrics.nix ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.phlip9-o11y = {
        server = {
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
            groupInterval = "100ms";
          };
        };
        collector.enable = true;
      };
      # Unused here: ssh (secrets are writeText, no sops)
      services.openssh.enable = lib.mkForce false;

      services.vmalert.instances."".rules.groups = [
        {
          name = "test";
          interval = "100ms";
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

      # Evaluate real groups right away (1ms max stagger; 0s panics in vmalert)
      # at a calm cadence; only the `test` group polls at 100ms. Keep
      # resendDelay at 1s so alert expiry stays 4s (4 * max(interval, resend)),
      # not 400ms.
      services.vmalert.instances."".settings = {
        evaluationInterval = "2s";
        "group.maxStartDelay" = "1ms";
        "rule.evalDelay" = "0s";
        "rule.resendDelay" = "1s";
      };
      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      # Keep the timer active for the unit check, but prevent wall-clock
      # `*:0/5` firings from racing w/ our manual `HOST_PING` runs.
      systemd.timers.healthchecks-host-ping.timerConfig.OnCalendar =
        lib.mkForce "2099-01-01 00:00:00";

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
    import datetime as dt
    import json
    import shlex
    import time
    from typing import Any

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        UP_TIMEOUT,
        dump_evidence,
        wait_for_cmd,
        wait_for_http,
        wait_for_port,
        wait_for_value,
    )
    from testlib.o11y import VM_URL, metric_sum, vm_flush

    SINK_LOG = "${sinkLog}"
    AM_URL = "http://127.0.0.1:9093"
    GF_URL = "http://127.0.0.1:3000"
    # `enforce_domain` redirects requests for any other Host.
    GF_CURL = (
        f"{CURL} --fail-with-body -u admin:gf-admin-testpwd "
        "-H 'Host: grafana.test'"
    )
    HOST_PING = "healthchecks-host-ping.service"

    # Requests the sink logged for `path`, oldest first. Uses `execute` so
    # poll loops don't spam the test log.
    def sink(path: str) -> list[dict[str, Any]]:
        rc, out = machine.execute(f"cat {SINK_LOG}", timeout=CMD_TIMEOUT)
        assert rc == 0, (rc, out)
        reqs = [json.loads(line) for line in out.splitlines()]
        return [req for req in reqs if req["path"] == path]

    # Discord webhook payloads: `{content, embeds: [{title, description}]}`
    def discord() -> list[dict[str, Any]]:
        return [json.loads(req["body"]) for req in sink("/discord")]

    # Discord messages w/ this embed title, ex: "FIRING:1 page TestPage"
    def discord_titled(title: str) -> list[dict[str, Any]]:
        return [msg for msg in discord() if msg["embeds"][0]["title"] == title]

    # Push samples (Prometheus text format) into VictoriaMetrics. Stamp them 5s
    # in the past (monotonic +10ms steps leave room for 500 pushes/sec while
    # staying <= current whole second) so vmalert's integer-second instant
    # query sees updates on the next 100ms eval instead of waiting for the next
    # second boundary. Flush immediately so VM's ~2s buffer doesn't hide them.
    push_ts_ms = 0

    def push(*lines: str) -> None:
        global push_ts_ms
        push_ts_ms = max(push_ts_ms + 10, (int(time.time()) - 5) * 1000)
        stamped = [f"{line} {push_ts_ms}" for line in lines]
        body = shlex.quote("\n".join(stamped) + "\n")
        machine.succeed(
            f"printf %s {body} | {CURL} -f --data-binary @- "
            f"{VM_URL}/api/v1/import/prometheus",
            timeout=CMD_TIMEOUT,
        )
        vm_flush(machine)

    # Alerts Alertmanager dropped from group flushes b/c of an inhibition.
    # Uses `execute` so poll loops don't spam the test log.
    def inhibited() -> float:
        rc, out = machine.execute(
            f"{CURL} -f {AM_URL}/metrics", timeout=CMD_TIMEOUT
        )
        assert rc == 0, (rc, out)
        return metric_sum(
            out.splitlines(),
            "alertmanager_notifications_suppressed_total",
            'reason="inhibition"',
        )

    # Active Alertmanager alerts (`/api/v2/alerts`). Uses `execute` so poll
    # loops don't spam the test log.
    def am_alerts() -> list[dict[str, Any]]:
        rc, out = machine.execute(
            f"{CURL} -f {AM_URL}/api/v2/alerts", timeout=CMD_TIMEOUT
        )
        assert rc == 0, (rc, out)
        return json.loads(out)

    # `(InvocationID, ActiveState, Result)` for `HOST_PING`. Uses `execute` so
    # poll loops don't spam the test log.
    def host_ping_state() -> tuple[str, str, str]:
        rc, out = machine.execute(
            "systemctl show -p InvocationID -p ActiveState -p Result "
            f"{HOST_PING}",
            timeout=CMD_TIMEOUT,
        )
        assert rc == 0, (rc, out)
        props = dict(
            line.split("=", 1) for line in out.splitlines() if "=" in line
        )
        return props["InvocationID"], props["ActiveState"], props["Result"]

    EVIDENCE = [(
        machine,
        [
            "journalctl --no-pager -o cat -u vmalert -u alertmanager "
            f"-u {HOST_PING} -u alert-sink | tail -n 100",
            f"cat {SINK_LOG}",
            f"{CURL} http://127.0.0.1:8880/api/v1/rules",
            f"{CURL} {AM_URL}/api/v2/alerts",
        ],
    )]

    machine.start()
    try:
        # Real rules evaluate against real (container) metrics, so a broken
        # expression shows up here as a rule error.
        with subtest("services start, vmalert evaluates every rule group"):
            machine.wait_for_unit("victoriametrics.service", timeout=UP_TIMEOUT)
            # Push all initial test series now while vmalert is still starting,
            # so VM's ~1s indexdb flush runs in parallel and `test_symptom`
            # (0 = not firing) is already indexed before we flip it to 1.
            push("test_page 1", "test_warn 1", "test_cause 1", "test_symptom 0")

            for unit in [
                "alert-sink.service",
                "alertmanager.service",
                "vmalert.service",
            ]:
                machine.wait_for_unit(unit, timeout=UP_TIMEOUT)
            wait_for_port(machine, ${toString sinkPort}, timeout=UP_TIMEOUT)
            wait_for_http(
                machine, "http://127.0.0.1:8880/health", timeout=UP_TIMEOUT
            )
            wait_for_http(machine, f"{AM_URL}/-/healthy", timeout=UP_TIMEOUT)

            # Start the healthy host-ping run now while vmalert evaluates rules
            # and alert subtests run, overlapping its ~1.1s sandboxed oneshot.
            # Timer uses OnCalendar=2099 in test so it won't fire on its own.
            machine.wait_for_unit(
                "healthchecks-host-ping.timer", timeout=UP_TIMEOUT
            )
            host_ping_inv = host_ping_state()[0]
            host_pings = len(sink("/host"))
            assert host_pings == 0, sink("/host")
            machine.succeed(f"systemctl start --no-block {HOST_PING}")

            # All rule groups, once every rule has run, else [].
            def rules_evaluated() -> list[dict[str, Any]]:
                rc, out = machine.execute(
                    f"{CURL} -f http://127.0.0.1:8880/api/v1/rules",
                    timeout=CMD_TIMEOUT,
                )
                if rc != 0:
                    return []
                groups = json.loads(out)["data"]["groups"]
                rules = [rule for group in groups for rule in group["rules"]]
                if any(r["lastEvaluation"].startswith("0001-") for r in rules):
                    return []
                return groups

            groups = wait_for_value(rules_evaluated, "vmalert rules evaluated")
            names = {group["name"] for group in groups}
            assert {"watchdog", "host", "storage", "test"} <= names, names
            errors = [
                (rule["name"], rule["lastError"])
                for group in groups
                for rule in group["rules"]
                if rule["lastError"]
            ]
            assert not errors, errors

        with subtest("page + warn + inhibit cause fire; start page resolve"):
            title = "FIRING:1 page TestPage"

            # Wait for both discord-quiet (full) and discord-page (@mention).
            def two_pages() -> list[dict[str, Any]] | None:
                got = discord_titled(title)
                assert len(got) <= 2, got
                return got if len(got) == 2 else None

            msgs = wait_for_value(two_pages, title)
            assert sorted(m["content"] for m in msgs) == ["", "<@12345>"], msgs
            full = next(m for m in msgs if m["content"] == "")
            desc = full["embeds"][0]["description"]
            assert desc.startswith("- **test_page**\n"), desc
            silence = "(https://grafana.test/alerting/silence/new?"
            assert silence in desc, desc
            # Resolve TestPage now so it overlaps w/ the checks below.
            push("test_page 0")

            warn_msgs = wait_for_value(
                lambda: discord_titled("FIRING:1 warn TestWarn"),
                "FIRING:1 warn TestWarn",
            )
            assert [m["content"] for m in warn_msgs] == [""], warn_msgs

        with subtest("inhibited symptom held back while its cause fires"):
            # Wait for PgDown to be active in Alertmanager before pushing the
            # symptom, so inhibition is deterministic.
            wait_for_value(
                lambda: discord_titled("FIRING:1 warn PgDown"),
                "FIRING:1 warn PgDown",
            )
            before = inhibited()
            push("test_symptom 1")

            # True once NixbotSymptom is specifically inhibited by PgDown and
            # Alertmanager has flushed + suppressed its group notification.
            def symptom_inhibited() -> bool:
                alerts = am_alerts()
                pg_fps = {
                    alert["fingerprint"]
                    for alert in alerts
                    if alert["labels"].get("alertname") == "PgDown"
                }
                if not pg_fps:
                    return False
                sym = [
                    alert
                    for alert in alerts
                    if alert["labels"].get("alertname") == "NixbotSymptom"
                ]
                return (
                    any(
                        pg_fps & set(alert["status"]["inhibitedBy"])
                        for alert in sym
                    )
                    and inhibited() > before
                )

            wait_for_value(symptom_inhibited, "symptom inhibited by PgDown")
            symptom = "FIRING:1 warn NixbotSymptom"
            assert not discord_titled(symptom), discord()
            push("test_cause 0")
            wait_for_value(lambda: discord_titled(symptom), symptom)

        with subtest("page resolve reaches Discord w/o mention"):
            resolved = wait_for_value(
                lambda: discord_titled("RESOLVED page TestPage"),
                "RESOLVED page TestPage",
            )
            assert all(m["content"] == "" for m in resolved), resolved

        # After the Discord subtests: every delivery above happened while
        # the Watchdog fired.
        with subtest("Watchdog pings healthchecks.io, never Discord"):
            ping = wait_for_value(
                lambda: sink("/watchdog"), "watchdog ping"
            )[0]
            assert ping["method"] == "POST", ping
            payload = json.loads(ping["body"])
            assert payload["status"] == "firing", payload
            assert payload["alerts"][0]["labels"]["alertname"] == "Watchdog"
            msgs = discord()
            assert all("Watchdog" not in json.dumps(m) for m in msgs), msgs
            # Recheck final sink snapshot in case a stray resolve mention
            # arrived.
            assert all(
                m["content"] == ""
                for m in discord_titled("RESOLVED page TestPage")
            ), msgs

        with subtest("host ping: ping if healthy, else skip it"):
            # `(ActiveState, Result)` once our async healthy run finishes.
            def host_ping_finished() -> tuple[str, str] | None:
                inv, state, result = host_ping_state()
                if inv != host_ping_inv and state not in (
                    "activating",
                    "deactivating",
                ):
                    return (state, result)
                return None

            state, result = wait_for_value(
                host_ping_finished, "healthy host ping"
            )
            assert (state, result) == ("inactive", "success"), (state, result)
            assert len(sink("/host")) == host_pings + 1, sink("/host")

            # The run succeeds: healthchecks.io's grace period is the signal.
            machine.succeed("systemctl stop vmalert.service")
            machine.succeed(f"systemctl start {HOST_PING}")
            unhealthy_inv = host_ping_state()[0]
            wait_for_cmd(
                machine,
                "journalctl -o cat "
                f"_SYSTEMD_INVOCATION_ID={shlex.quote(unhealthy_inv)} "
                "| grep -q 'vmalert: vmalert.service is not active'",
                timeout=dt.timedelta(seconds=10),
            )
            assert len(sink("/host")) == host_pings + 1, sink("/host")

        with subtest("Grafana Alertmanager datasource"):
            machine.wait_for_unit("grafana.service", timeout=UP_TIMEOUT)
            # Grafana's datasource test: GET /api/v2/status through its proxy
            wait_for_cmd(
                machine,
                f"{GF_CURL} {GF_URL}/api/datasources/proxy/uid/alertmanager"
                "/api/v2/status | jq -e .cluster",
                timeout=UP_TIMEOUT,
            )
    except Exception:
        dump_evidence(EVIDENCE)
        raise
  '';
}
