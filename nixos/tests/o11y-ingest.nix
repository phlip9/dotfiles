# NixOS container test: the o11y ingest endpoint + a remote collector.
#
# Two containers:
# - `server`: o11y server (VictoriaMetrics, Pyroscope) w/ `server.ingest` on
#   an HTTPS-only nginx vhost (self-signed cert), w/o a collector of its own
# - `collector`: collector only, `collector.remote` -> https://server/o11y
#
# Verifies:
# - vmagent remote-writes through nginx w/ basic auth, VictoriaMetrics'
#   zstd protocol, HTTP/1.1; the password stays out of argv + the unit
#   user's reach
# - `instance` = the credential's username: vmagent's scrape target, a
#   crafted write's body label, and its `extra_label` query args can't
#   override it; a second credential gets its own instance
# - no / wrong / unknown credentials -> 401, a username w/ URL syntax ->
#   403, and none of their writes are stored
# - only the 2 ingest endpoints, POST only: other paths, `..`, `%2F`, and
#   methods are rejected; no read API is reachable
# - the body limit: 16 MiB, over the vhost's own 256k
# - profiles: a pprof pushed w/ `profilecli` through nginx over HTTP/2 w/
#   basic auth reads back from Pyroscope; w/o or w/ wrong credentials it's
#   rejected + not stored
#
# Alloy's push through the ingest endpoint needs eBPF, so a VM: see
# ./o11y-profiling-ebpf.nix.
let
  # Ingest credentials: username = collector hostname
  passwords = {
    collector = "collector-test-password-0123456789";
    collector2 = "collector2-test-password-0123456789";
    # In the htpasswd file w/ a valid password, but the username has URL
    # syntax: nginx must reject it before it reaches the upstream URL.
    "evil&extra_label=job=pwned" = "evil-test-password-0123456789";
  };

  # Labels of the fixture profile
  service = "o11y-ingest-test";
  profileType = "process_cpu:cpu:nanoseconds:cpu:nanoseconds";
  # A function in the fixture's stacks
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
      # Unused here: Grafana, ssh, pyroscope-du (blocks multi-user.target)
      services.grafana.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;
      systemd.services.pyroscope-du.enable = lib.mkForce false;
      systemd.timers.pyroscope-du.enable = lib.mkForce false;

      # Like sauna's vhost: HTTPS-only, w/ a small body limit that the
      # ingest locations override.
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

      # Like a sops secret w/ `owner = config.services.nginx.user`
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
        # profilecli, same version as the server's
        containers.server.services.pyroscope.package
      ];

      # Go CPU profile w/ ~50 samples, from Pyroscope's own test data, see
      # ./o11y-profiling.nix
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
        # A scrape target that claims another host: vmagent sends its
        # `instance`, the server must replace it.
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
      # Unused here: node metrics, ssh
      services.prometheus.exporters.node.enable = lib.mkForce false;
      services.openssh.enable = lib.mkForce false;

      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      # Like a root-only sops secret, w/ its trailing newline
      environment.etc."o11y-ingest/password" = {
        text = "${passwords.collector}\n";
        mode = "0400";
      };
    };

  testScript = ''
    import base64
    import datetime as dt
    import json
    import shlex
    import struct
    import time

    VM_URL = "http://127.0.0.1:8428"
    PYRO_URL = "http://127.0.0.1:4040"
    VMAGENT_URL = "http://127.0.0.1:8429"
    INGEST = "https://server/o11y"
    WRITE = f"{INGEST}/metrics/api/v1/write"
    PUSH = f"{INGEST}/profiles/push.v1.PusherService/Push"
    # Bound every request, so a hung server fails its step, not the test's
    # globalTimeout, and `dump_evidence` still runs.
    CURL = "curl -sS --connect-timeout 2 --max-time 10"
    # Upper bound for one command, incl. its curl
    CMD_TIMEOUT = dt.timedelta(seconds=15)
    # Upper bound for a scrape or push to show up
    WAIT_TIMEOUT = dt.timedelta(seconds=30)

    PASSWORDS = json.loads(${builtins.toJSON (builtins.toJSON passwords)})
    EVIL = "evil&extra_label=job=pwned"
    SERVICE = "${service}"
    PROFILE_TYPE = "${profileType}"
    HOT_FN = "${hotFn}"
    SELECTOR = f'{{service_name="{SERVICE}"}}'

    def dump_evidence() -> None:
        for node, cmds in [
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
        ]:
            for cmd in cmds:
                _, out = node.execute(cmd, timeout=CMD_TIMEOUT)
                print(f"{node.name}$ {cmd}\n{out}")

    # --- Prometheus remote write v1, by hand: protobuf + snappy --- #

    def varint(num: int) -> bytes:
        out = bytearray()
        while num >= 0x80:
            out.append(num & 0x7F | 0x80)
            num >>= 7
        out.append(num)
        return bytes(out)

    # Length-delimited protobuf field
    def proto_field(field: int, data: bytes) -> bytes:
        return varint(field << 3 | 2) + varint(len(data)) + data

    # Snappy block w/o compression: the length, then one literal
    def snappy_literal(data: bytes) -> bytes:
        size = len(data) - 1
        if size < 60:
            tag = bytes([size << 2])
        else:
            nbytes = (size.bit_length() + 7) // 8
            tag = bytes([(59 + nbytes) << 2]) + size.to_bytes(nbytes, "little")
        return varint(len(data)) + tag + data

    # `WriteRequest` w/ one series per label list, each w/ one sample (1 at
    # now). Label lists may repeat a name.
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

    # Basic auth (username, password); default: the collector's own
    COLLECTOR = ("collector", PASSWORDS["collector"])

    # curl from the collector w/ `auth` (None: no credentials). Returns the
    # HTTP status. nginx may reset an oversize upload mid-send: a status
    # w/ a curl error still counts.
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

    # Run `(url, method)` requests in one `curl -K -` invocation, reusing one
    # HTTP/2 TLS connection. Returns one HTTP status per entry.
    def batch_requests(
        reqs: list[tuple[str, str]],
        auth: tuple[str, str] = COLLECTOR,
    ) -> list[str]:
        creds = ":".join(auth)
        stanzas = []
        for url, method in reqs:
            method_opt = (
                "head"
                if method == "HEAD"
                else f"request = {json.dumps(method)}"
            )
            stanzas.append("\n".join([
                f"url = {json.dumps(url)}",
                f"user = {json.dumps(creds)}",
                'output = "/dev/null"',
                'write-out = "%{http_code}\\n"',
                "path-as-is",
                "connect-timeout = 2",
                "max-time = 10",
                method_opt,
            ]))
        cfg = "\nnext\n".join(stanzas) + "\n"
        # `execute` (not `succeed`): avoids logging the 39-stanza config twice
        rc, out = collector.execute(
            f"printf %s {shlex.quote(cfg)} | curl -sS -K -",
            timeout=CMD_TIMEOUT,
        )
        assert rc == 0, (rc, out)
        statuses = out.splitlines()
        assert len(statuses) == len(reqs), (len(statuses), len(reqs), out)
        return statuses

    # Remote write `series` through the ingest endpoint. Returns the status.
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

    # Instant query on the server's VictoriaMetrics, optionally flushing
    # pending rows first.
    def vm_query(promql: str, flush: bool = True) -> list[dict]:
        query = shlex.quote(promql)
        prefix = f"{CURL} -f {VM_URL}/internal/force_flush && " if flush else ""
        out = server.succeed(
            prefix
            + f"{CURL} -f {VM_URL}/api/v1/query --data-urlencode query={query}",
            timeout=CMD_TIMEOUT,
        )
        return json.loads(out)["data"]["result"]

    def labels_of(promql: str, flush: bool = True) -> list[dict]:
        return [res["metric"] for res in vm_query(promql, flush=flush)]

    # Poll `check` until it holds, back to back, w/o `retry`'s 1s sleeps:
    # each check blocks on a guest command.
    def wait_fast(
        check, what: str, timeout: dt.timedelta = WAIT_TIMEOUT
    ) -> None:
        deadline = time.monotonic() + timeout.total_seconds()
        while not check():
            if time.monotonic() > deadline:
                raise Exception(f"timed out: {what}")

    # Poll `promql` until it returns series, back to back: each query
    # blocks on a guest command. A new series turns searchable on VM's ~1s
    # indexdb flush tick, even after `/internal/force_flush`.
    def wait_for_labels(promql: str, flush_each: bool = True) -> list[dict]:
        if not flush_each:
            server.succeed(
                f"{CURL} -f {VM_URL}/internal/force_flush", timeout=CMD_TIMEOUT
            )
        got: list[dict] = []

        def check() -> bool:
            nonlocal got
            got = labels_of(promql, flush=flush_each)
            return bool(got)

        wait_fast(check, promql)
        return got

    # Sum of vmagent's own metric `name` w/ `match` in its labels. None:
    # vmagent isn't serving yet.
    def vmagent_metric(name: str, match: str = "") -> float | None:
        status, out = collector.execute(
            f"{CURL} -f {VMAGENT_URL}/metrics", timeout=CMD_TIMEOUT
        )
        if status != 0:
            return None
        return sum(
            float(line.rsplit(" ", 1)[1])
            for line in out.splitlines()
            if line.startswith((name + "{", name + " ")) and match in line
        )

    # Poll until vmagent's metric `name` w/ `match` is > 0
    def wait_for_vmagent(name: str, match: str = "") -> None:
        wait_fast(
            lambda: (vmagent_metric(name, match) or 0) > 0,
            f"{name}{{{match}}} > 0",
        )

    start_all()
    try:
        with subtest("server + collector up"):
            server.wait_for_unit("victoriametrics.service")
            server.wait_for_unit("nginx.service")
            # nginx is Type=simple: wait until it has bound :443
            wait_fast(
                lambda: server.execute(
                    "ss -Hltn 'sport = :443' | grep -q :443",
                    timeout=CMD_TIMEOUT,
                )[0] == 0,
                "nginx :443",
            )
            collector.wait_for_unit("vmagent.service")

        # The source is root-only, vmagent (DynamicUser) reads its copy
        with subtest("vmagent password: a credential, not in argv"):
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

        # Send all crafted + rejected writes now so VM's ~1s indexdb flush
        # tick overlaps w/ the endpoint, body-limit, and profile subtests.
        with subtest("crafted + bad-credential writes: HTTP status"):
            ok = [("__name__", "o11y_test_ok"), ("job", "crafted")]
            assert write([ok]) == "204"

            # Spoofed in the body, also twice
            body_spoof = [
                ("__name__", "o11y_test_body"), ("instance", "evil"),
                ("job", "crafted"), ("instance", "evil2"),
            ]
            assert write([body_spoof]) == "204"

            # Spoofed in the query string, incl. VM's handshake arg
            args_spoof = [("__name__", "o11y_test_args"), ("job", "crafted")]
            query = (
                "?extra_label=instance=evil&extra_label=job=evil"
                "&get_vm_proto_version=1"
            )
            assert write([args_spoof], query=query) == "204"

            # Another host's credential: its own instance
            second = [
                ("__name__", "o11y_test_second"), ("instance", "collector"),
            ]
            collector2 = ("collector2", PASSWORDS["collector2"])
            assert write([second], auth=collector2) == "204"

            rejected = {
                "o11y_test_noauth": (None, "401"),
                "o11y_test_nouser": (("nobody", PASSWORDS["collector"]), "401"),
                "o11y_test_badpw": (("collector", "wrong"), "401"),
                # Another host's password
                "o11y_test_otherpw": (
                    ("collector", PASSWORDS["collector2"]), "401"
                ),
                # A valid credential, but its username has URL syntax
                "o11y_test_evil": ((EVIL, PASSWORDS[EVIL]), "403"),
            }
            for name, (auth, code) in rejected.items():
                status = write([[("__name__", name)]], auth=auth)
                assert status == code, (name, status)
            out = collector.succeed(
                f"{CURL} -X POST -D - -o /dev/null {WRITE}", timeout=CMD_TIMEOUT
            )
            assert "www-authenticate: basic" in out.lower(), out

            # Sentinel written after all crafted + rejected writes: once it is
            # searchable, any accepted write above would be too.
            assert write([[("__name__", "o11y_test_after")]]) == "204"

        with subtest("only the 2 endpoints, POST only, no read API"):
            # w/ valid credentials, so auth isn't what rejects them
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
                [(url, method) for url, method, _ in checks]
            )
            for (url, method, want), got in zip(checks, statuses):
                assert got == want, (url, method, got, want)

        with subtest("body limit: 16 MiB, not the vhost's 256k"):
            collector.succeed(
                "truncate -s 15M /tmp/15m && truncate -s 17M /tmp/17m",
                timeout=CMD_TIMEOUT,
            )
            headers = "-H 'Content-Encoding: snappy' "
            # Reaches VictoriaMetrics, which can't parse it
            assert request(WRITE, headers + "--data-binary @/tmp/15m") == "400"
            assert request(WRITE, headers + "--data-binary @/tmp/17m") == "413"

        with subtest("profiles: push w/ basic auth over HTTP/2, read back"):
            upload = (
                f"profilecli upload --url {INGEST}/profiles "
                "--username collector --override-timestamp "
                "--extra-labels service_name={service} "
                "/etc/o11y-test/cpu.pb.gz"
            )
            # Auth rejections happen in nginx, before Pyroscope needs /ready
            collector.fail(
                "PROFILECLI_PASSWORD=wrong "
                + upload.format(service="o11y-ingest-badpw"),
                timeout=CMD_TIMEOUT,
            )
            assert request(PUSH, "-X POST", auth=None) == "401"

            # Wait here so Pyroscope's Raft election overlaps w/ metrics tests
            wait_fast(
                lambda: server.execute(
                    f"curl -sf --connect-timeout 2 --max-time 10 "
                    f"{PYRO_URL}/ready",
                    timeout=CMD_TIMEOUT,
                )[0] == 0,
                "pyroscope /ready",
                timeout=dt.timedelta(seconds=60),
            )
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

            window = {"start": push_ms - 60_000, "end": push_ms + 600_000}

            def pyro_post(method: str, body: dict) -> dict:
                data = shlex.quote(json.dumps({**window, **body}))
                return json.loads(server.succeed(
                    f"{CURL} -f -H 'Content-Type: application/json' "
                    f"--data-binary {data} "
                    f"{PYRO_URL}/querier.v1.QuerierService/{method}",
                    timeout=CMD_TIMEOUT,
                ))

            def has_hot_fn() -> bool:
                resp = pyro_post("SelectMergeStacktraces", {
                    "profileTypeID": PROFILE_TYPE,
                    "labelSelector": SELECTOR,
                })
                return HOT_FN in resp.get("flamegraph", {}).get("names", [])

            wait_fast(has_hot_fn, f"profile w/ {HOT_FN}")
            services = pyro_post(
                "LabelValues", {"name": "service_name"}
            ).get("names", [])
            assert services == [SERVICE], services

        with subtest("vmagent writes through ingest, instance pinned"):
            # `up` per job: its instance, once every job's first scrape
            # arrived
            wait_for_labels('count(up) >= 3')
            jobs = {
                labels["job"]: labels["instance"]
                for labels in labels_of("up", flush=False)
            }
            assert jobs == {
                "vmagent": "collector",
                "nixos-exporter": "collector",
                "spoof": "collector",
            }, jobs
            # vmagent sent `instance="spoofed"` for this one
            spoof = labels_of('vm_app_version{job="spoof"}', flush=False)
            instances = [labels["instance"] for labels in spoof]
            assert instances == ["collector"], spoof
            assert labels_of('{instance="spoofed"}', flush=False) == []

            # VictoriaMetrics' zstd protocol, no downgrade to snappy. Its
            # samples can turn visible before vmagent counts the response.
            wait_for_vmagent(
                "vmagent_remotewrite_requests_total", 'status_code="2XX"'
            )
            assert vmagent_metric(
                "vmagent_remotewrite_requests_total", 'status_code="400"'
            ) == 0
            collector.fail(
                "journalctl -u vmagent | grep -E 'Re-packing|Downgrading'",
                timeout=CMD_TIMEOUT,
            )
            server.succeed(
                "grep -qF '\"POST /o11y/metrics/api/v1/write HTTP/1.1\" 204' "
                "/var/log/nginx/access.log",
                timeout=CMD_TIMEOUT,
            )

        with subtest("crafted writes stored, rejected absent"):
            wait_for_labels("o11y_test_after", flush_each=False)
            got = sorted(
                labels_of('{__name__=~"o11y_test_.*"}', flush=False),
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
            assert labels_of('{job="pwned"}', flush=False) == []
            instances = {
                labels["instance"]
                for labels in labels_of(
                    'count by (instance) ({__name__!=""})', flush=False
                )
            }
            assert instances == {"collector", "collector2"}, instances
    except Exception:
        dump_evidence()
        raise
  '';
}
