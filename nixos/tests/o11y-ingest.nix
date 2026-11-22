# Exercise o11y ingest across two NixOS containers over HTTPS.
#
#   collector (vmagent, profilecli) -> server (nginx /o11y)
#                                    -> VictoriaMetrics, Pyroscope
#
# - Metrics: vmagent zstd writes over HTTP/1.1 and auth-derived instance labels.
# - Ingress: password handling, auth failures, POST-only routes, and body limit.
# - Profiles: authenticated profilecli push over HTTP/2 and Pyroscope readback.
#
# Use fixture credentials and a self-signed cert for offline HTTPS.
# Alloy's eBPF collector runs in a separate VM test.
# see: nixos/tests/o11y-profiling-ebpf.nix
let
  # The auth username sets the stored instance label.
  passwords = {
    collector = "collector-test-password-0123456789";
    collector2 = "collector2-test-password-0123456789";
    # Pass basic auth to exercise username validation.
    "evil&extra_label=job=pwned" = "evil-test-password-0123456789";
  };

  # Profile labels and a known stack frame for readback.
  service = "o11y-ingest-test";
  profileType = "process_cpu:cpu:nanoseconds:cpu:nanoseconds";
  hotFn = "main.slowFunction";
in
{
  name = "o11y-ingest";

  globalTimeout = 300;

  containers.server =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      ingestLib = import ./lib/o11y-ingest.nix { inherit pkgs; };
      tls = ingestLib.tlsCert "server";

      # Match the newline in production sops secret files.
      secret = name: text: pkgs.writeText name "${text}\n";
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.phlip9-o11y.server = {
        enable = true;
        retentionPeriod = "1d";
        grafana = {
          adminPasswordFile = secret "gf-admin-pwd" "gf-admin-testpwd";
          secretKeyFile = secret "gf-secret-key" "test-secret-key-0123456789";
          secretsManagerKeyFile = secret "gf-sm-key" "test-sm-key-0123456789";
        };
        profiling.enable = true;
        ingest = {
          enable = true;
          vhost = "server";
          htpasswdFile = "/etc/o11y-ingest/htpasswd";
        };
      };

      services.grafana.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      # Skip the disk usage scan so it can't delay multi-user.target.
      systemd.services.pyroscope-du.enable = lib.mkForce false;
      systemd.timers.pyroscope-du.enable = lib.mkForce false;

      # Set a lower vhost body limit to exercise the ingest override.
      # see: nixos/mods/o11y/server/ingest.nix
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        virtualHosts.server = {
          onlySSL = true;
          sslCertificate = "${tls}/cert.pem";
          sslCertificateKey = "${tls}/key.pem";
          extraConfig = ''
            client_max_body_size 256k;
          '';
        };
      };
      networking.firewall.allowedTCPPorts = [ 443 ];

      # Match the permissions of the production htpasswd secret.
      # see: nixos/sauna/default.nix
      environment.etc."o11y-ingest/htpasswd" = {
        source = ingestLib.htpasswd passwords;
        mode = "0400";
        user = config.services.nginx.user;
        group = config.services.nginx.group;
      };
    };

  containers.collector =
    {
      containers,
      lib,
      pkgs,
      ...
    }:
    let
      ingestLib = import ./lib/o11y-ingest.nix { inherit pkgs; };
      tls = ingestLib.tlsCert "server";
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        # Use profilecli from the server's Pyroscope build.
        containers.server.services.pyroscope.package
      ];

      # Copy only the Go CPU profile from Pyroscope's test data.
      environment.etc."o11y-test/cpu.pb.gz".source =
        pkgs.runCommand "pyroscope-cpu.pb.gz" { }
          ''
            cp ${pkgs.pyroscope.src}/pkg/og/convert/pprof/testdata/cpu.pb.gz $out
          '';

      security.pki.certificateFiles = [ "${tls}/cert.pem" ];

      services.phlip9-o11y.collector = {
        enable = true;
        remote = {
          url = "https://server/o11y";
          passwordFile = "/etc/o11y-ingest/password";
        };

        # Send an explicit instance label to test server-side replacement.
        scrapeConfigs.spoof = {
          static_configs = [
            {
              targets = [ "127.0.0.1:8429" ];
              labels.instance = "spoofed";
            }
          ];
          metric_relabel_configs = [
            {
              source_labels = [ "__name__" ];
              regex = "vm_app_version";
              action = "keep";
            }
          ];
        };
      };

      services.prometheus.exporters.node.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      # Match a root-only sops secret, including its trailing newline.
      environment.etc."o11y-ingest/password" = {
        text = "${passwords.collector}\n";
        mode = "0400";
      };
    };

  testScript = ''
    import base64
    import json
    import shlex
    import struct
    import time

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        batch_requests,
        dump_evidence,
        wait_fast,
        wait_for_http,
        wait_for_port,
        wait_for_value,
    )
    from testlib.o11y import (
        PYRO_URL,
        VMAGENT_URL,
        metric_sum,
        metrics_scrape,
        pyro_fn_names,
        pyro_label_values,
        pyro_window,
        vm_labels,
        wait_for_vm_labels,
    )

    INGEST = "https://server/o11y"
    WRITE = f"{INGEST}/metrics/api/v1/write"
    PUSH = f"{INGEST}/profiles/push.v1.PusherService/Push"

    PASSWORDS = json.loads(${builtins.toJSON (builtins.toJSON passwords)})
    EVIL = "evil&extra_label=job=pwned"
    SERVICE = "${service}"
    PROFILE_TYPE = "${profileType}"
    HOT_FN = "${hotFn}"
    SELECTOR = f'{{service_name="{SERVICE}"}}'

    EVIDENCE = [
        (server, [
            "journalctl --no-pager -o cat -u nginx | tail -n 60",
            "tail -n 60 /var/log/nginx/access.log",
            "journalctl --no-pager -o cat -u victoriametrics | tail -n 30",
            "journalctl --no-pager -o cat -u pyroscope | tail -n 30",
        ]),
        (collector, [
            "journalctl --no-pager -o cat -u vmagent | tail -n 60",
            f"{CURL} {VMAGENT_URL}/metrics "
            "| grep -E '^vmagent_remotewrite_'",
        ]),
    ]

    # --- Remote write v1 fixtures --- #

    # Encode a protobuf varint as 7-bit chunks with continuation bits.
    def varint(num: int) -> bytes:
        out = bytearray()
        while num >= 0x80:
            out.append(num & 0x7F | 0x80)
            num >>= 7
        out.append(num)
        return bytes(out)

    # Encode a length-delimited protobuf field.
    def proto_field(field: int, data: bytes) -> bytes:
        return varint(field << 3 | 2) + varint(len(data)) + data

    # Encode a Snappy block as its uncompressed length and one literal.
    def snappy_literal(data: bytes) -> bytes:
        size = len(data) - 1
        if size < 60:
            tag = bytes([size << 2])
        else:
            nbytes = (size.bit_length() + 7) // 8
            tag = bytes([(59 + nbytes) << 2]) + size.to_bytes(nbytes, "little")
        return varint(len(data)) + tag + data

    # Encode one current sample per series and preserve duplicate label names.
    def write_request(series: list[list[tuple[str, str]]]) -> bytes:
        now_ms = int(time.time() * 1000)
        sample = (
            varint(1 << 3 | 1) + struct.pack("<d", 1.0)
            + varint(2 << 3) + varint(now_ms)
        )
        body = b""
        for labels in series:
            ts = b"".join(
                proto_field(1, proto_field(1, name.encode())
                            + proto_field(2, value.encode()))
                for name, value in labels
            )
            body += proto_field(1, ts + proto_field(2, sample))
        return snappy_literal(body)

    # --- Ingest requests --- #

    COLLECTOR = ("collector", PASSWORDS["collector"])

    # Use the HTTP status even if nginx resets an oversized upload mid-send.
    def request(
        url: str, args: str = "", auth: tuple[str, str] | None = COLLECTOR
    ) -> str:
        auth_arg = ""
        if auth is not None:
            auth_arg = "-u " + shlex.quote(":".join(auth))
        _, out = collector.execute(
            f"{CURL} -o /dev/null -w '%{{http_code}}' {auth_arg} {args} "
            + shlex.quote(url),
            timeout=CMD_TIMEOUT,
        )
        status = out.strip().splitlines()[-1] if out.strip() else ""
        assert len(status) == 3 and status != "000", (url, args, out)
        return status

    # Send a remote write fixture from the collector and return its status.
    def write(
        series: list[list[tuple[str, str]]],
        auth: tuple[str, str] | None = COLLECTOR,
        query: str = "",
    ) -> str:
        body = base64.b64encode(write_request(series)).decode()
        auth_arg = ""
        if auth is not None:
            auth_arg = "-u " + shlex.quote(":".join(auth))
        _, out = collector.execute(
            f"printf %s {shlex.quote(body)} | base64 -d | "
            f"{CURL} -o /dev/null -w '%{{http_code}}' {auth_arg} "
            "-H 'Content-Encoding: snappy' "
            "-H 'Content-Type: application/x-protobuf' "
            "--data-binary @- " + shlex.quote(WRITE + query),
            timeout=CMD_TIMEOUT,
        )
        status = out.strip().splitlines()[-1] if out.strip() else ""
        assert len(status) == 3 and status != "000", (query, out)
        return status

    start_all()
    try:
        # --- Startup and credentials --- #

        with subtest("Ingest server and collector readiness"):
            server.wait_for_unit("victoriametrics.service")
            server.wait_for_unit("nginx.service")
            # nginx can be active before it binds the HTTPS port.
            wait_for_port(server, 443)
            collector.wait_for_unit("vmagent.service")

        with subtest("vmagent gets its password through systemd credentials"):
            # DynamicUser reads the credential copy of the root-only source.
            pw = PASSWORDS["collector"]
            collector.succeed(
                "test \"$(stat -c %a:%U /etc/o11y-ingest/password)\" "
                "= 400:root",
                "test -s /run/credentials/vmagent.service/"
                "remote_write_basic_auth_password",
                timeout=CMD_TIMEOUT,
            )
            collector.fail(
                f"grep -aF {shlex.quote(pw)} "
                "/proc/$(systemctl show -p MainPID --value vmagent)/cmdline",
                timeout=CMD_TIMEOUT,
            )

        # --- Ingest HTTP contract --- #

        with subtest("Remote write status for valid and invalid credentials"):
            # Send writes early so indexing overlaps the HTTP and profile tests.
            ok = [("__name__", "o11y_test_ok"), ("job", "crafted")]
            assert write([ok]) == "204"

            # Exercise replacement of every duplicate instance label.
            body_spoof = [
                ("__name__", "o11y_test_body"), ("instance", "evil"),
                ("job", "crafted"), ("instance", "evil2"),
            ]
            assert write([body_spoof]) == "204"

            # Verify label overrides are ignored even with the handshake flag.
            args_spoof = [("__name__", "o11y_test_args"), ("job", "crafted")]
            query = (
                "?extra_label=instance=evil&extra_label=job=evil"
                "&get_vm_proto_version=1"
            )
            assert write([args_spoof], query=query) == "204"

            # The second credential must set its own instance.
            second = [
                ("__name__", "o11y_test_second"), ("instance", "collector"),
            ]
            collector2 = ("collector2", PASSWORDS["collector2"])
            assert write([second], auth=collector2) == "204"

            rejected = {
                "o11y_test_noauth": (None, "401"),
                "o11y_test_nouser": (("nobody", PASSWORDS["collector"]), "401"),
                "o11y_test_badpw": (("collector", "wrong"), "401"),
                "o11y_test_otherpw": (
                    ("collector", PASSWORDS["collector2"]), "401"
                ),
                "o11y_test_evil": ((EVIL, PASSWORDS[EVIL]), "403"),
            }
            for name, (auth, code) in rejected.items():
                status = write([[("__name__", name)]], auth=auth)
                assert status == code, (name, status)
            out = collector.succeed(
                f"{CURL} -X POST -D - -o /dev/null {WRITE}", timeout=CMD_TIMEOUT
            )
            assert "www-authenticate: basic" in out.lower(), out

            # Write a sentinel so the final query can check for rejected rows
            # after earlier accepted writes become searchable.
            assert write([[("__name__", "o11y_test_after")]]) == "204"

        with subtest("Only POST on the two ingest routes is allowed"):
            # Use valid credentials to isolate path and method restrictions.
            not_found = [
                "/o11y", "/o11y/", "/o11y/metrics", "/o11y/metrics/",
                "/o11y/metrics/api/v1/query?query=up",
                "/o11y/metrics/api/v1/query_range",
                "/o11y/metrics/api/v1/import",
                "/o11y/metrics/api/v1/export",
                "/o11y/metrics/metrics",
                "/o11y/metrics/vmui/",
                "/o11y/metrics/api/v1/write/",
                "/o11y/metrics/api/v1/write/../query",
                "/o11y/metrics/api/v1/../v1/query",
                "/o11y/metrics/api%2Fv1%2Fquery",
                "/o11y/metrics/api/v1/write%3Fquery=up",
                "/o11y/metrics/api/v1/write;query",
                "/o11y/profiles",
                "/o11y/profiles/",
                "/o11y/profiles/ingest",
                "/o11y/profiles/querier.v1.QuerierService/LabelNames",
                "/o11y/profiles/push.v1.PusherService/Push/../../"
                "querier.v1.QuerierService/LabelNames",
                "/o11y/profiles/push.v1.PusherService%2F..%2F..%2F"
                "querier.v1.QuerierService/LabelNames",
                "/api/v1/query?query=up",
                "/api/v1/write",
                "/push.v1.PusherService/Push",
                "/querier.v1.QuerierService/LabelNames",
                "/metrics",
            ]
            checks = [
                (f"https://server{path}", "POST", "404") for path in not_found
            ] + [
                (url, method, "403")
                for url in [WRITE, PUSH]
                for method in ["GET", "HEAD", "PUT", "DELETE",
                               "OPTIONS", "PATCH"]
            ]
            statuses = batch_requests(
                collector,
                [(url, method) for url, method, _ in checks],
                auth=COLLECTOR,
            )
            for (url, method, want), got in zip(checks, statuses):
                assert got == want, (url, method, got, want)

        with subtest("Ingest applies its 16 MiB body limit"):
            collector.succeed(
                "truncate -s 15M /tmp/15m && truncate -s 17M /tmp/17m",
                timeout=CMD_TIMEOUT,
            )
            headers = "-H 'Content-Encoding: snappy' "
            # The malformed 15 MiB request reaches VictoriaMetrics' decoder.
            assert request(WRITE, headers + "--data-binary @/tmp/15m") == "400"
            assert request(WRITE, headers + "--data-binary @/tmp/17m") == "413"

        # --- Profile ingest --- #

        with subtest("HTTP/2 profile push, readback, and auth rejection"):
            upload = (
                f"profilecli upload --url {INGEST}/profiles "
                "--username collector --override-timestamp "
                "--extra-labels service_name={service} "
                "/etc/o11y-test/cpu.pb.gz"
            )
            # nginx can reject credentials while Pyroscope starts.
            collector.fail(
                "PROFILECLI_PASSWORD=wrong "
                + upload.format(service="o11y-ingest-badpw"),
                timeout=CMD_TIMEOUT,
            )
            assert request(PUSH, "-X POST", auth=None) == "401"

            # Delay the readiness wait to overlap Raft election w/ prior checks.
            wait_for_http(server, f"{PYRO_URL}/ready")
            push_ms = int(time.time() * 1000)
            collector.succeed(
                f"PROFILECLI_PASSWORD={shlex.quote(PASSWORDS['collector'])} "
                + upload.format(service=SERVICE),
                timeout=CMD_TIMEOUT,
            )
            server.succeed(
                "grep -qF '\"POST /o11y/profiles/push.v1.PusherService/Push "
                "HTTP/2.0\" 200' /var/log/nginx/access.log",
                timeout=CMD_TIMEOUT,
            )

            window = pyro_window(push_ms, before_ms=60_000, after_ms=600_000)
            wait_fast(
                lambda: HOT_FN in pyro_fn_names(
                    server, PROFILE_TYPE, SELECTOR, window=window
                ),
                f"profile stack containing {HOT_FN}",
            )
            services = pyro_label_values(server, "service_name", window=window)
            assert services == [SERVICE], services

        # --- Metrics readback --- #

        with subtest("vmagent HTTP/1.1 writes use the auth username"):
            # Wait for the first scrapes before checking stored job labels.
            wait_for_vm_labels(server, 'count(up) >= 3')
            jobs = {
                labels["job"]: labels["instance"]
                for labels in vm_labels(server, "up", flush=False)
            }
            assert jobs == {
                "vmagent": "collector",
                "nixos-exporter": "collector",
                "spoof": "collector",
            }, jobs
            # Check the actual payload metric from the spoof target too.
            spoof = vm_labels(
                server, 'vm_app_version{job="spoof"}', flush=False
            )
            instances = [labels["instance"] for labels in spoof]
            assert instances == ["collector"], spoof
            assert vm_labels(server, '{instance="spoofed"}', flush=False) == []

            # Samples can become visible before vmagent records the response.
            def scrape_2xx() -> list[str] | None:
                lines = metrics_scrape(collector, VMAGENT_URL)
                if (
                    metric_sum(
                        lines,
                        "vmagent_remotewrite_requests_total",
                        'status_code="2XX"',
                    )
                    > 0
                ):
                    return lines
                return None

            scrape = wait_for_value(
                scrape_2xx, "vmagent records a successful remote write"
            )
            assert (
                metric_sum(
                    scrape,
                    "vmagent_remotewrite_requests_total",
                    'status_code="400"',
                )
                == 0
            )
            # A zstd write should succeed without repacking or downgrading.
            collector.fail(
                "journalctl -u vmagent | grep -E 'Re-packing|Downgrading'",
                timeout=CMD_TIMEOUT,
            )
            server.succeed(
                "grep -qF '\"POST /o11y/metrics/api/v1/write HTTP/1.1\" 204' "
                "/var/log/nginx/access.log",
                timeout=CMD_TIMEOUT,
            )

        with subtest("Only accepted writes appear under auth labels"):
            # Wait for the sentinel before asserting which series are absent.
            wait_for_vm_labels(server, "o11y_test_after", flush_each=False)
            got = sorted(
                vm_labels(server, '{__name__=~"o11y_test_.*"}', flush=False),
                key=lambda labels: labels["__name__"],
            )
            expected = sorted(
                [
                    {
                        "__name__": "o11y_test_ok",
                        "job": "crafted",
                        "instance": "collector",
                    },
                    {
                        "__name__": "o11y_test_body",
                        "job": "crafted",
                        "instance": "collector",
                    },
                    {
                        "__name__": "o11y_test_args",
                        "job": "crafted",
                        "instance": "collector",
                    },
                    {
                        "__name__": "o11y_test_second",
                        "instance": "collector2",
                    },
                    {
                        "__name__": "o11y_test_after",
                        "instance": "collector",
                    },
                ],
                key=lambda labels: labels["__name__"],
            )
            assert got == expected, got
            assert vm_labels(server, '{job="pwned"}', flush=False) == []
            instances = {
                labels["instance"]
                for labels in vm_labels(
                    server, 'count by (instance) ({__name__!=""})', flush=False
                )
            }
            assert instances == {"collector", "collector2"}, instances
    except Exception:
        dump_evidence(EVIDENCE)
        raise
  '';
}
