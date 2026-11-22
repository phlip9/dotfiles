# Exercise the phlip9-o11y collector and server in one NixOS container.
#
# - Metrics: exporters -> vmagent -> VictoriaMetrics <- Grafana queries.
# - Grafana: secrets manager key, Git Sync setup and crash recovery.
# - Dashboards: Git Sync file/API round trip and just/grafana-*.sh workflows.
#
# Use writeText secrets and a local Git Sync repo to keep the test offline.
# see: nixos/mods/o11y/default.nix
{
  name = "o11y";

  globalTimeout = 600;

  containers.machine =
    { lib, pkgs, ... }:
    let
      grafanaAdminPassword = "gf-admin-testpwd";
      grafanaAdminPasswordFile = pkgs.writeText "gf-admin-pwd" grafanaAdminPassword;
      grafanaSecretKeyFile = pkgs.writeText "gf-secret-key" "test-secret-key-0123456789abcdef";
      grafanaSecretsManagerKeyFile = pkgs.writeText "gf-secrets-manager-key" "test-secrets-manager-key-0123456789";

      # Package the dashboard scripts and their shared jq library for the guest.
      grafanaScripts =
        pkgs.runCommand "grafana-scripts"
          {
            src = lib.fileset.toSource {
              root = ../../just;
              fileset = lib.fileset.fileFilter (
                file:
                file.name == "grafana.jq"
                || (lib.hasPrefix "grafana-" file.name && file.hasExt "sh")
              ) ../../just;
            };
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
            buildInputs = [ pkgs.bash ];
          }
          ''
            mkdir -p $out/bin $out/libexec
            cp $src/grafana-*.sh $src/grafana.jq $out/libexec/
            patchShebangs --host $out/libexec
            for script in $out/libexec/grafana-*.sh; do
              name=$(basename "$script" .sh)
              if [[ $name != grafana-lib ]]; then
                makeWrapper "$script" "$out/bin/$name" \
                  --prefix PATH : ${
                    lib.makeBinPath [
                      pkgs.curl
                      pkgs.jq
                    ]
                  }
              fi
            done
          '';
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.sqlite
        grafanaScripts
      ];

      services.phlip9-o11y = {
        server = {
          enable = true;
          retentionPeriod = "1d";
          grafana.adminPasswordFile = grafanaAdminPasswordFile;
          grafana.secretKeyFile = grafanaSecretKeyFile;
          grafana.secretsManagerKeyFile = grafanaSecretsManagerKeyFile;

          grafana.gitSync = {
            enable = true;
            title = "machine";
            type = "local";
            local.path = "/var/lib/grafana-git-sync";
            # Minimum interval accepted by the module.
            intervalSeconds = 10;
            homeDashboard = "test-sync";
          };
        };
        collector.enable = true;
      };

      # Fixture secrets skip sops, so the shared SSH host key is unused.
      services.openssh.enable = lib.mkForce false;

      # Keep in sync w/ queryOptions.interval in the range query fixture below.
      services.vmagent.prometheusConfig.global.scrape_interval = "1s";

      services.grafana.settings.security.admin_user = "testadmin";

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

      # Bypass DNS validation for the GitHub repo used to store a dummy token.
      services.grafana.settings.provisioning.allowed_git_urls = "github.com";
    };

  testScript = ''
    import datetime as dt
    import json
    import shlex
    from typing import Any

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        UP_TIMEOUT,
        dump_evidence,
        wait_for_cmd,
        wait_for_http,
        wait_for_value,
    )
    from testlib.o11y import (
        VM_URL,
        metric_sum,
        metrics_scrape,
    )

    GF_URL = "http://127.0.0.1:3000"
    GF_API = f"{GF_URL}/api"
    GF_AUTH = "-u testadmin:gf-admin-testpwd"
    GF_CURL = f"{CURL} --fail-with-body {GF_AUTH}"
    JSON_HDR = "-H 'Content-Type: application/json'"
    REPOS_URL = (
        f"{GF_URL}/apis/provisioning.grafana.app"
        "/v0alpha1/namespaces/default/repositories"
    )
    GS_DIR = "/var/lib/grafana-git-sync"
    GS_REPO_URL = f"{REPOS_URL}/dotfiles"
    GS_DASH_FILE = f"{GS_DIR}/test-sync.json"
    DASHES_URL = (
        f"{GF_URL}/apis/dashboard.grafana.app/v2"
        "/namespaces/default/dashboards"
    )
    DASH_URL = f"{DASHES_URL}/test-sync"
    GS_SETUP = "grafana-git-sync-setup.service"

    # Scrape nixos-exporter into a map keyed by metric name and labels.
    def nixos_metrics() -> dict[str, str]:
        out = machine.succeed(
            f"{CURL} -w '\\n%{{http_code}}' http://127.0.0.1:9101/metrics",
            timeout=CMD_TIMEOUT,
        )
        out, _, status = out.rpartition("\n")
        assert status == "200", f"{status}: {out}"
        return dict(
            line.split(" ", 1)
            for line in out.splitlines()
            if not line.startswith("#")
        )

    # Query instant PromQL results quietly for polling, flushing by default.
    def vm_query_quiet(
        promql: str, *, flush: bool = True
    ) -> list[dict[str, Any]]:
        prefix = f"{CURL} -f {VM_URL}/internal/force_flush && " if flush else ""
        rc, out = machine.execute(
            prefix
            + f"{CURL} -f {VM_URL}/api/v1/query "
            f"--data-urlencode query={shlex.quote(promql)}",
            timeout=CMD_TIMEOUT,
        )
        if rc != 0:
            return []
        return json.loads(out)["data"]["result"]

    # Check that the authenticated caller gets HTTP 404.
    def assert_http_404(url: str) -> None:
        out = machine.succeed(
            f"{CURL} {GF_AUTH} -o /dev/null -w '%{{http_code}}' "
            f"{shlex.quote(url)}",
            timeout=CMD_TIMEOUT,
        )
        assert out.strip() == "404", (url, out)

    # Trigger a full Git Sync pull so tests can skip the periodic sync interval.
    def git_sync_pull() -> None:
        pull = shlex.quote(
            json.dumps({"action": "pull", "pull": {"incremental": False}})
        )
        post_pull = (
            f"{CURL} {GF_AUTH} -w '\\n%{{http_code}}' {JSON_HDR} "
            f"-d {pull} {GS_REPO_URL}/jobs"
        )

        # Pulls share the <repo>-sync name. Retry 409 while that job exists.
        def queue_pull() -> str | None:
            rc, out = machine.execute(post_pull, timeout=CMD_TIMEOUT)
            assert rc == 0, (rc, out)
            body, _, status = out.rpartition("\n")
            resp = json.loads(body)
            if status == "409" and resp.get("reason") == "AlreadyExists":
                return None
            assert status.startswith("2"), (status, resp)
            return resp["metadata"]["uid"]

        job_uid = wait_for_value(queue_pull, "queue Git Sync pull")

        # Job lookup by UID returns 404 until Grafana archives the finished job.
        def archived_job() -> dict[str, Any] | None:
            rc, out = machine.execute(
                f"{CURL} {GF_AUTH} -w '\\n%{{http_code}}' "
                f"{GS_REPO_URL}/jobs/{job_uid}",
                timeout=CMD_TIMEOUT,
            )
            assert rc == 0, (rc, out)
            body, _, status = out.rpartition("\n")
            if status == "404":
                return None
            assert status == "200", (status, body)
            return json.loads(body)

        job = wait_for_value(
            archived_job,
            f"archived Git Sync pull {job_uid}",
            timeout=UP_TIMEOUT,
        )
        assert job["status"]["state"] == "success", job["status"]

    # Create a service account and return the path to its token file.
    def sa_token(name: str, role: str) -> str:
        sa = shlex.quote(json.dumps({"name": name, "role": role}))
        sa_id = machine.succeed(
            f"{GF_CURL} {JSON_HDR} -d {sa} {GF_API}/serviceaccounts "
            "| jq -er .id",
            timeout=CMD_TIMEOUT,
        ).strip()
        token = shlex.quote(json.dumps({"name": name}))
        path = f"/tmp/{name}-token"
        machine.succeed(
            f"{GF_CURL} {JSON_HDR} -d {token} "
            f"{GF_API}/serviceaccounts/{sa_id}/tokens | jq -er .key > {path}",
            timeout=CMD_TIMEOUT,
        )
        return path

    # Read unit state quietly so recovery polling stays out of the log.
    def unit_state(unit: str) -> tuple[str, str, str]:
        rc, out = machine.execute(
            f"systemctl show -p InvocationID -p ActiveState -p Result {unit}",
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
            "journalctl --no-pager -o cat -u victoriametrics -u vmagent "
            f"-u nixos-exporter -u grafana -u {GS_SETUP} | tail -n 120",
            f"{CURL} {VM_URL}/api/v1/query?query=up",
            f"{CURL} {GF_AUTH} {GS_REPO_URL}",
        ],
    )]

    machine.start()
    try:
        # Count a setup run if it queues a pull or finds one already queued.
        # see: nixos/mods/o11y/server/grafana.nix
        gs_setup_pulls = (
            f"journalctl -o cat -u {GS_SETUP} "
            "| grep -cE '(triggered pull job|sync job already queued) "
            "for repository dotfiles'"
        )

        # --- Startup and crash recovery --- #

        with subtest("Grafana startup, secrets manager, and Git Sync setup"):
            machine.wait_for_unit("grafana.service", timeout=UP_TIMEOUT)
            machine.wait_for_unit(GS_SETUP, timeout=UP_TIMEOUT)
            wait_for_cmd(
                machine,
                f"{GF_CURL} {GF_API}/health | jq -e '.database == \"ok\"'",
                timeout=UP_TIMEOUT,
            )

            # Store a dummy token to verify Grafana uses our secret_key.v2
            # provider for data keys.
            repo = {
                "apiVersion": "provisioning.grafana.app/v0alpha1",
                "kind": "Repository",
                "metadata": {"name": "secrets-test", "namespace": "default"},
                "spec": {
                    "title": "secrets-test",
                    "type": "github",
                    "workflows": [],
                    "sync": {"enabled": False, "target": "folder"},
                    "webhook": {"disabled": True},
                    "github": {
                        "url": "https://github.com/example/test",
                        "branch": "main",
                    },
                },
                "secure": {"token": {"create": "dummy-token"}},
            }
            machine.succeed(
                f"{GF_CURL} {JSON_HDR} "
                f"-d {shlex.quote(json.dumps(repo))} {REPOS_URL}",
                timeout=CMD_TIMEOUT,
            )
            providers = machine.succeed(
                # Wait for concurrent Grafana writes to release SQLite locks.
                "sqlite3 -cmd '.timeout 10000' "
                "/var/lib/grafana/data/grafana.db "
                "'SELECT DISTINCT provider FROM secret_data_key'",
                timeout=CMD_TIMEOUT,
            )
            assert providers.strip() == "secret_key.v2", providers
            machine.succeed(
                f"{GF_CURL} -X DELETE {REPOS_URL}/secrets-test",
                timeout=CMD_TIMEOUT,
            )

            machine.succeed(
                f"{GF_CURL} {GS_REPO_URL} | jq -e '"
                ".spec.type == \"local\" "
                "and .spec.sync.target == \"folder\" "
                "and .spec.workflows == [\"write\"] "
                "and .status.health.healthy == true'",
                f"{gs_setup_pulls} | grep -qx 1",
                f"{GF_CURL} {GF_API}/org/preferences "
                "| jq -e '.homeDashboardUID == \"test-sync\"'",
                timeout=CMD_TIMEOUT,
            )
            wait_for_cmd(
                machine,
                f"{GF_CURL} {GS_REPO_URL}/jobs | jq -e '.items | any("
                ".spec.action == \"pull\" and .status.state == \"success\")'",
                timeout=UP_TIMEOUT,
            )

            # Check the setup unit's lifecycle dependencies on Grafana.
            wiring = machine.succeed(
                f"systemctl show -p WantedBy -p PartOf -p Requires -p After "
                f"{GS_SETUP}",
                timeout=CMD_TIMEOUT,
            )
            props = dict(
                line.split("=", 1)
                for line in wiring.splitlines()
                if "=" in line
            )
            for key in ("WantedBy", "PartOf", "Requires", "After"):
                assert "grafana.service" in props[key].split(), (key, props)

            # Start recovery now so it can overlap the nixos-exporter checks.
            gs_setup_inv = unit_state(GS_SETUP)[0]
            machine.succeed(
                "systemctl kill --signal=KILL grafana.service",
                timeout=CMD_TIMEOUT,
            )

        with subtest("nixos-exporter boot, system, and cgroup metrics"):
            machine.wait_for_unit("nixos-exporter.service", timeout=UP_TIMEOUT)

            # The test driver leaves the system profile unset. Seed it w/ the
            # booted system as generation 1.
            profiles = "/nix/var/nix/profiles"
            boot_state = "/var/lib/private/nixos-exporter/boots"
            machine.succeed(
                f"mkdir -p {profiles}",
                f"ln -sfn $(readlink /run/booted-system) "
                f"{profiles}/system-1-link",
                f"ln -sfn system-1-link {profiles}/system",
                timeout=CMD_TIMEOUT,
            )

            metrics = nixos_metrics()
            assert metrics["nixos_boots_total"] == "1", metrics
            assert metrics["nixos_system_generation"] == "1", metrics
            assert metrics["nixos_reboot_required"] == "0", metrics

            # The exporter rounds switch timestamps to milliseconds.
            switch_ts = float(
                machine.succeed(
                    "stat -c %.9Y /run/current-system", timeout=CMD_TIMEOUT
                )
            )
            switch_metric = float(
                metrics["nixos_system_switch_timestamp_seconds"]
            )
            assert abs(switch_metric - switch_ts) <= 0.001, (
                switch_ts,
                metrics,
            )

            # Start the exporter on boot so it counts even unscraped boots.
            wanted_by = machine.succeed(
                "systemctl show -p WantedBy --value nixos-exporter.service",
                timeout=CMD_TIMEOUT,
            )
            assert "multi-user.target" in wanted_by.split(), wanted_by

            # Simulate a new boot by replacing the saved boot ID between
            # exporter runs. Stop the socket to prevent scrape activation.
            boot_id = machine.succeed(
                "cat /proc/sys/kernel/random/boot_id", timeout=CMD_TIMEOUT
            ).strip()
            machine.succeed(
                "systemctl stop nixos-exporter.socket nixos-exporter.service",
                f"sed -i 's/ .*/ old-boot-id/' {boot_state}",
                "systemctl start nixos-exporter.service",
                timeout=CMD_TIMEOUT,
            )
            wait_for_cmd(
                machine,
                f"grep -qx '2 {boot_id}' {boot_state}",
                timeout=dt.timedelta(seconds=10),
            )

            # Point generation 2 at a fake kernel to trigger the reboot flag.
            # Use /srv so the fixture is visible under PrivateTmp.
            machine.succeed(
                "mkdir /srv/system-2",
                "ln -s /nix/store/fake-linux/bzImage /srv/system-2/kernel",
                f"ln -sfn /srv/system-2 {profiles}/system-2-link",
                f"ln -sfn system-2-link {profiles}/system",
                timeout=CMD_TIMEOUT,
            )
            metrics = nixos_metrics()
            assert metrics["nixos_boots_total"] == "2", metrics
            assert metrics["nixos_system_generation"] == "2", metrics
            assert metrics["nixos_reboot_required"] == "1", metrics

            # cpu.stat is available in the sandbox without delegated memory
            # or I/O controllers.
            for slice_name, unit in [
                ("-.slice", "system.slice"),
                ("system.slice", "nixos-exporter.service"),
            ]:
                labels = f'slice="{slice_name}",unit="{unit}"'
                name = f"nixos_cgroup_cpu_seconds_total{{{labels}}}"
                assert float(metrics.get(name, "0")) > 0, (name, metrics)

        with subtest("Grafana crash recovery re-runs Git Sync setup"):
            # Wait for the new invocation to finish before checking its result.
            def gs_setup_recovered() -> tuple[str, str, str] | None:
                inv, state, result = unit_state(GS_SETUP)
                if inv != gs_setup_inv and state not in (
                    "activating",
                    "deactivating",
                ):
                    return (inv, state, result)
                return None

            new_inv, state, result = wait_for_value(
                gs_setup_recovered,
                "Git Sync setup after Grafana crash",
                timeout=UP_TIMEOUT,
            )
            assert (state, result) == ("active", "success"), (state, result)
            machine.succeed(
                "systemctl show -P NRestarts grafana.service | grep -qx 1",
                timeout=CMD_TIMEOUT,
            )
            wait_for_cmd(
                machine,
                "journalctl -o cat "
                f"_SYSTEMD_INVOCATION_ID={shlex.quote(new_inv)} "
                "| grep -q 'updated repository dotfiles'",
                timeout=dt.timedelta(seconds=10),
            )
            machine.succeed(
                f"{gs_setup_pulls} | grep -qx 2", timeout=CMD_TIMEOUT
            )

        # --- Metrics pipeline --- #

        with subtest("vmagent remote write and Grafana datasource queries"):
            machine.wait_for_unit("victoriametrics.service", timeout=UP_TIMEOUT)
            wait_for_http(machine, f"{VM_URL}/ping", timeout=UP_TIMEOUT)

            jobs = {
                "victoriametrics",
                "vmagent",
                "node-exporter",
                "nixos-exporter",
                "grafana",
            }
            last_up: list[dict[str, Any]] = []

            # Wait for the new boot count and one healthy series per job.
            def all_targets_scraped() -> list[dict[str, Any]] | None:
                boots = vm_query_quiet(
                    'nixos_boots_total{job="nixos-exporter"}', flush=True
                )
                if not boots or boots[0]["value"][1] != "2":
                    return None
                last_up[:] = vm_query_quiet("up", flush=False)
                seen = [
                    (
                        row["metric"].get("job"),
                        row["metric"].get("instance"),
                        row["value"][1],
                    )
                    for row in last_up
                ]
                if (
                    len(seen) == len(jobs)
                    and {job for job, _, _ in seen} == jobs
                    and all(
                        inst == "machine" and val == "1"
                        for _, inst, val in seen
                    )
                ):
                    return last_up
                return None

            try:
                wait_for_value(
                    all_targets_scraped, "five healthy jobs and boot count 2"
                )
            except TimeoutError as err:
                raise TimeoutError(f"{err}\nlast up={last_up}") from err

            # Check the ingestion path after proving samples arrived.
            targets = json.loads(
                machine.succeed(
                    f"{CURL} -f {VM_URL}/api/v1/targets", timeout=CMD_TIMEOUT
                )
            )["data"]
            assert targets["activeTargets"] == [], targets
            vm_scrape = metrics_scrape(machine, VM_URL)
            assert (
                metric_sum(
                    vm_scrape,
                    "vm_rows_inserted_total",
                    'type="promscrape"',
                )
                == 0
            ), vm_scrape
            assert (
                metric_sum(
                    vm_scrape,
                    "vm_rows_inserted_total",
                    'type="promremotewrite"',
                )
                > 0
            ), vm_scrape

            machine.succeed(
                f"{GF_CURL} {GF_API}/datasources/uid/victoriametrics "
                "| jq -e '.name == \"VictoriaMetrics (Plugin)\"'",
                timeout=CMD_TIMEOUT,
            )
            wait_for_cmd(
                machine,
                f"{GF_CURL} "
                f"'{GF_API}/datasources/proxy/uid/victoriametrics"
                "/api/v1/query?query=up' "
                "| jq -e '.data.result | length > 0'",
            )
            wait_for_cmd(
                machine,
                f"{GF_CURL} "
                f"'{GF_API}/datasources/proxy/uid/victoriametrics"
                "/api/v1/label/__name__/values' "
                "| jq -e '.data | any(index(\"vm_app_version\"))'",
            )

        # --- Git Sync dashboard lifecycle --- #

        gf_url_env = f"GRAFANA_URL={GF_URL}"
        gf_env = (
            f"{gf_url_env} GRAFANA_USER=testadmin "
            "GRAFANA_PASSWORD=gf-admin-testpwd"
        )

        # Match the Editor role used by mcp-grafana.
        editor_token = sa_token("editor", "Editor")
        editor_env = f"{gf_url_env} GRAFANA_TOKEN_FILE={editor_token}"
        machine.succeed(
            "printf 'Authorization: Bearer %s' "
            f"\"$(cat {editor_token})\" > /tmp/editor-auth",
            timeout=CMD_TIMEOUT,
        )
        editor_curl = f"{CURL} --fail-with-body -H @/tmp/editor-auth"

        # Minimal v2 manifest in the same format as the deployed dashboards.
        # see: nixos/sauna/grafana/
        dashboard = {
            "apiVersion": "dashboard.grafana.app/v2",
            "kind": "Dashboard",
            "metadata": {"name": "test-sync"},
            "spec": {
                "title": "Git Sync Test",
                "timeSettings": {"from": "now-6h", "to": "now"},
                "variables": [],
                "elements": {},
                "layout": {"kind": "GridLayout", "spec": {"items": []}},
            },
        }

        with subtest("Git Sync provisions the root folder and home dashboard"):
            machine.succeed(
                f"echo {shlex.quote(json.dumps(dashboard))} "
                "> /tmp/test-sync.json",
                "install -o grafana -g grafana -m 0640 "
                f"/tmp/test-sync.json {GS_DASH_FILE}",
                timeout=CMD_TIMEOUT,
            )
            git_sync_pull()
            dash = json.loads(
                machine.succeed(
                    f"{GF_CURL} {DASH_URL}", timeout=CMD_TIMEOUT
                )
            )
            assert dash["spec"]["title"] == "Git Sync Test", dash
            annos = dash["metadata"]["annotations"]
            assert annos["grafana.app/managedBy"] == "repo", annos
            assert annos["grafana.app/managerId"] == "dotfiles", annos
            gs_folder = annos["grafana.app/folder"]
            assert gs_folder == "dotfiles", annos
            machine.succeed(
                f"{GF_CURL} {GF_API}/folders/{gs_folder} "
                "| jq -e '.title == \"machine\" and .parentUid == null "
                "and .managedBy == \"repo\"'",
                f"{GF_CURL} {GF_API}/dashboards/home "
                "| jq -e '.redirectUri | startswith(\"/d/test-sync/\")'",
                timeout=CMD_TIMEOUT,
            )

        with subtest("Git Sync writes API saves to repository"):
            # Keep the management annotations so the save routes to Git Sync.
            machine.succeed(
                f"{GF_CURL} {DASH_URL} "
                "| jq '.spec.title = \"Git Sync Test (edited)\"' "
                "> /tmp/edited.json",
                f"{GF_CURL} -X PUT {JSON_HDR} "
                f"--data-binary @/tmp/edited.json {DASH_URL}",
                timeout=CMD_TIMEOUT,
            )
            wait_for_cmd(
                machine,
                "jq -e '.spec.title == \"Git Sync Test (edited)\"' "
                f"{GS_DASH_FILE}",
            )
            machine.succeed(
                f"{GF_CURL} {DASH_URL} "
                "| jq -e '.spec.title == \"Git Sync Test (edited)\"'",
                timeout=CMD_TIMEOUT,
            )

        with subtest("grafana-check dry-runs updates"):
            # Check both the API revision and the file where real saves land.
            dash_meta = (
                f"{GF_CURL} {DASH_URL} "
                "| jq -c '.metadata | [.generation, .resourceVersion]'"
            )
            dash_file_sum = f"sha256sum {GS_DASH_FILE}"
            before = machine.succeed(
                dash_meta, dash_file_sum, timeout=CMD_TIMEOUT
            )
            out = machine.succeed(
                f"{gf_env} grafana-check {GS_DASH_FILE}", timeout=CMD_TIMEOUT
            )
            assert out == f"ok   {GS_DASH_FILE}\n", out
            after = machine.succeed(
                dash_meta, dash_file_sum, timeout=CMD_TIMEOUT
            )
            assert before == after, (before, after)

        with subtest("grafana-check rejects invalid manifests"):
            # Exercise server validation on both the update and create paths.
            machine.succeed(
                f"jq '.spec.title = 42' {GS_DASH_FILE} > /tmp/bad-title.json",
                "jq '.metadata.name = \"no-title\" | .spec.title = \"\"' "
                f"{GS_DASH_FILE} > /tmp/no-title.json",
                timeout=CMD_TIMEOUT,
            )
            status, out = machine.execute(
                f"{gf_env} grafana-check /tmp/bad-title.json "
                f"/tmp/no-title.json {GS_DASH_FILE}",
                timeout=CMD_TIMEOUT,
            )
            lines = out.splitlines()
            assert status == 1, out
            assert lines[0].startswith(
                "FAIL /tmp/bad-title.json: HTTP 400: "
            ), out
            assert "spec.title of type string" in lines[0], out
            assert lines[1].startswith(
                "FAIL /tmp/no-title.json: HTTP 400: "
            ), out
            assert "title cannot be empty" in lines[1], out
            assert lines[2] == f"ok   {GS_DASH_FILE}", out

        with subtest("Editors inherit access to Git Sync dashboards"):
            machine.succeed(
                f"{editor_curl} {DASH_URL} "
                "| jq -e '.spec.title == \"Git Sync Test (edited)\"'",
                timeout=CMD_TIMEOUT,
            )
            out = machine.succeed(
                f"{editor_env} grafana-check {GS_DASH_FILE}",
                timeout=CMD_TIMEOUT,
            )
            assert out == f"ok   {GS_DASH_FILE}\n", out

            # Explicit basic auth takes precedence over the token file.
            status, out = machine.execute(
                f"{gf_url_env} GRAFANA_USER=testadmin GRAFANA_PASSWORD=bad "
                f"GRAFANA_TOKEN_FILE={editor_token} "
                f"grafana-check {GS_DASH_FILE}",
                timeout=CMD_TIMEOUT,
            )
            assert status == 1, out
            assert out.startswith(f"FAIL {GS_DASH_FILE}: HTTP 401"), out

        # --- Scratch dashboard workflow --- #

        with subtest("Editor creates and edits a Scratch dashboard"):
            # Prove grafana-push creates the folder on first use.
            assert_http_404(f"{GF_API}/folders/scratch")
            seed = dict(dashboard["spec"], title="Scratch Seed")
            out = machine.succeed(
                f"echo {shlex.quote(json.dumps(seed))} > /tmp/promote.json",
                f"{editor_env} grafana-push /tmp/promote.json",
                timeout=CMD_TIMEOUT,
            )
            assert out.endswith("/d/scratch-promote\n"), out
            machine.succeed(
                f"{GF_CURL} {GF_API}/folders/scratch "
                "| jq -e '.title == \"Scratch\"'",
                f"{editor_curl} {DASHES_URL}/scratch-promote "
                "| jq -e '.spec.title == \"Scratch Seed\" "
                "and .metadata.annotations[\"grafana.app/folder\"] "
                "== \"scratch\"'",
                f"{editor_curl} {DASHES_URL}/scratch-promote "
                "| jq '.spec.title = \"Promote <&> Test\"' > /tmp/edit.json",
                f"{editor_curl} -X PUT {JSON_HDR} "
                f"--data-binary @/tmp/edit.json {DASHES_URL}/scratch-promote",
                timeout=CMD_TIMEOUT,
            )

        with subtest("Git Sync preserves unmanaged Scratch dashboards"):
            git_sync_pull()
            machine.succeed(
                f"{GF_CURL} {DASHES_URL}/scratch-promote "
                "| jq -e '.metadata.annotations "
                "| .[\"grafana.app/folder\"] == \"scratch\" "
                "and .[\"grafana.app/managedBy\"] == null'",
                f"{GF_CURL} {GF_API}/folders/scratch",
                f"{GF_CURL} {DASH_URL}",
                timeout=CMD_TIMEOUT,
            )

        with subtest("grafana-promote produces stable Git Sync manifests"):
            promote = f"{editor_env} grafana-promote"
            promoted = "/tmp/promote/promote.json"
            machine.succeed(
                f"{promote} scratch-promote {promoted}",
                f"cp {promoted} /tmp/promote-first.json",
                # The second run reuses the UID from the existing file.
                f"{promote} scratch-promote {promoted}",
                f"cmp {promoted} /tmp/promote-first.json",
                # Match Go's JSON escaping of <, &, and >.
                f"grep -qF '\\u003c\\u0026\\u003e' {promoted}",
                timeout=CMD_TIMEOUT,
            )
            manifest = json.loads(
                machine.succeed(f"cat {promoted}", timeout=CMD_TIMEOUT)
            )
            assert manifest["apiVersion"] == "dashboard.grafana.app/v2", (
                manifest
            )
            assert manifest["kind"] == "Dashboard", manifest
            assert manifest["metadata"] == {"name": "promote"}, manifest
            assert manifest["spec"]["title"] == "Promote <&> Test", manifest
            assert "status" not in manifest, manifest

            # Check UID overrides and byte parity w/ Git Sync's serializer.
            machine.succeed(
                f"{promote} scratch-promote /tmp/promote/other.json other",
                "jq -e '.metadata.name == \"other\"' /tmp/promote/other.json",
                f"{promote} test-sync /tmp/promote/test-sync.json test-sync",
                f"cmp /tmp/promote/test-sync.json {GS_DASH_FILE}",
                timeout=CMD_TIMEOUT,
            )

            status, out = machine.execute(
                f"{promote} scratch-no /tmp/x.json 2>&1", timeout=CMD_TIMEOUT
            )
            assert status == 1 and "not found" in out, (status, out)

        with subtest("grafana-check dry-runs creates"):
            out = machine.succeed(
                f"{gf_env} grafana-check {promoted}", timeout=CMD_TIMEOUT
            )
            assert out == f"ok   {promoted}\n", out
            assert_http_404(f"{DASHES_URL}/promote")

        with subtest("grafana-push enforces file baselines and Scratch scope"):
            push = f"{editor_env} grafana-push"
            title_is = (
                f"{editor_curl} {DASHES_URL}/scratch-promote "
                "| jq -e --arg t {} '.spec.title == $t'"
            ).format

            # Assert the push fails for the expected reason.
            def refused(args: str, msg: str) -> None:
                status, out = machine.execute(
                    f"{push} {args} 2>&1", timeout=CMD_TIMEOUT
                )
                assert status == 1 and msg in out, (args, status, out)

            # Promotion records the baseline for this file.
            machine.succeed(
                f"jq '.spec.title = \"Pushed\"' {promoted} > /tmp/edit.json",
                f"mv /tmp/edit.json {promoted}",
                f"{push} {promoted} scratch-promote",
                title_is("Pushed"),
                timeout=CMD_TIMEOUT,
            )

            # Pushing a file without a baseline requires --force.
            machine.succeed(
                f"jq '.spec' {GS_DASH_FILE} > /tmp/bare.json",
                timeout=CMD_TIMEOUT,
            )
            refused("/tmp/bare.json scratch-promote", "never pushed/promoted")
            machine.succeed(
                f"{push} --force /tmp/bare.json scratch-promote",
                title_is("'Git Sync Test (edited)'"),
                timeout=CMD_TIMEOUT,
            )

            # A UI edit makes the baseline stale. Promoting to a second file
            # must leave the first file's baseline stale.
            machine.succeed(
                f"{GF_CURL} {DASHES_URL}/scratch-promote "
                "| jq '.spec.title = \"UI Edit\"' > /tmp/ui-edit.json",
                f"{GF_CURL} -X PUT {JSON_HDR} --data-binary @/tmp/ui-edit.json "
                f"{DASHES_URL}/scratch-promote",
                timeout=CMD_TIMEOUT,
            )
            refused(
                "/tmp/bare.json scratch-promote", "changed since our last push"
            )
            machine.succeed(
                f"{editor_env} grafana-promote scratch-promote "
                "/tmp/pulled.json",
                timeout=CMD_TIMEOUT,
            )
            refused(
                "/tmp/bare.json scratch-promote", "changed since our last push"
            )

            # Push w/ the fresh baseline, then force the file w/ a stale one.
            machine.succeed(
                "jq '.spec.title = \"Pulled\"' /tmp/pulled.json "
                "> /tmp/edit.json",
                "mv /tmp/edit.json /tmp/pulled.json",
                f"{push} /tmp/pulled.json scratch-promote",
                title_is("Pulled"),
                f"{push} --force /tmp/bare.json scratch-promote",
                title_is("'Git Sync Test (edited)'"),
                timeout=CMD_TIMEOUT,
            )

            # The UID prefix and folder are independent guards.
            refused(f"{GS_DASH_FILE} test-sync", "no scratch- prefix")
            machine.succeed(
                f"{GF_CURL} {JSON_HDR} "
                "-d '{\"uid\": \"other\", \"title\": \"Other\"}' "
                f"{GF_API}/folders",
                timeout=CMD_TIMEOUT,
            )
            elsewhere = {
                "apiVersion": "dashboard.grafana.app/v2",
                "kind": "Dashboard",
                "metadata": {
                    "name": "scratch-in-other",
                    "annotations": {"grafana.app/folder": "other"},
                },
                "spec": dict(dashboard["spec"], title="Elsewhere"),
            }
            machine.succeed(
                f"echo {shlex.quote(json.dumps(elsewhere))} > /tmp/else.json",
                f"{GF_CURL} {JSON_HDR} --data-binary @/tmp/else.json "
                f"{DASHES_URL}",
                timeout=CMD_TIMEOUT,
            )
            refused("/tmp/bare.json scratch-in-other", "refusing to overwrite")
            machine.succeed(
                f"{GF_CURL} {DASHES_URL}/scratch-in-other "
                "| jq -e '.spec.title == \"Elsewhere\"'",
                timeout=CMD_TIMEOUT,
            )

        # --- Dashboard queries and inspection --- #

        with subtest("Grafana panel queries and dashboard lookup by UID"):
            # Build a v2 time series panel w/ a datasource variable.
            def panel(key: str, exprs: list[str]) -> dict[str, Any]:
                queries = [
                    {
                        "kind": "PanelQuery",
                        "spec": {
                            "refId": ref,
                            "hidden": False,
                            "query": {
                                "kind": "DataQuery",
                                "group": "victoriametrics-metrics-datasource",
                                "version": "v0",
                                "datasource": {"name": "''${DS}"},
                                "spec": {"expr": expr},
                            },
                        },
                    }
                    for ref, expr in zip("ABC", exprs)
                ]
                return {
                    "kind": "Panel",
                    "spec": {
                        "id": 1,
                        "title": key,
                        "data": {
                            "kind": "QueryGroup",
                            "spec": {
                                # Match the 1s scrape interval so the range
                                # grid hits samples even on fast test runs.
                                "queryOptions": {"interval": "1s"},
                                "queries": queries,
                            },
                        },
                        "vizConfig": {
                            "kind": "VizConfig",
                            "group": "timeseries",
                            "spec": {},
                        },
                    },
                }

            spec = {
                "title": "Queries",
                "variables": [
                    {
                        "kind": "DatasourceVariable",
                        "spec": {
                            "name": "DS",
                            "pluginId": "victoriametrics-metrics-datasource",
                            "current": {"value": "victoriametrics"},
                        },
                    },
                    {
                        "kind": "QueryVariable",
                        "spec": {
                            "name": "job",
                            "current": {"value": ["$__all"]},
                        },
                    },
                    # Test an All value that matches no job.
                    {
                        "kind": "QueryVariable",
                        "spec": {
                            "name": "nojob",
                            "includeAll": True,
                            "allValue": "none",
                            "current": {"value": "$__all"},
                        },
                    },
                ],
                "elements": {
                    "good": panel(
                        "good",
                        [
                            'up{job=~"$job"}',
                            "rate(vm_http_requests_total[$__rate_interval])",
                        ],
                    ),
                    "empty": panel("empty", ["no_such_metric"]),
                    "bad": panel("bad", ["up{"]),
                    "allvalue": panel("allvalue", ['up{job=~"$nojob"}']),
                    "fmt": panel("fmt", ['up{job=~"''${job:json}"}']),
                },
                "layout": {"kind": "GridLayout", "spec": {"items": []}},
            }

            # rate() needs at least two samples from the same series.
            def rate_ready() -> bool:
                res = vm_query_quiet(
                    "count_over_time(vm_http_requests_total[5m])"
                )
                return any(float(row["value"][1]) >= 2 for row in res)

            wait_for_value(rate_ready, "vm_http_requests_total >= 2 samples")
            machine.succeed(
                f"echo {shlex.quote(json.dumps(spec))} > /tmp/queries.json",
                timeout=CMD_TIMEOUT,
            )
            queries = f"{editor_env} grafana-queries --from now-5m"
            status, out = machine.execute(
                f"{queries} /tmp/queries.json", timeout=CMD_TIMEOUT
            )
            assert status == 1, out
            lines = {line.split()[1]: line for line in out.splitlines()[1:]}
            assert lines["bad/A"].startswith("FAIL "), out
            assert lines["empty/A"].startswith("EMPTY "), out
            assert lines["good/A"].startswith("ok "), out
            assert lines["good/B"].startswith("ok "), out
            assert lines["allvalue/A"].startswith("EMPTY "), out
            assert lines["fmt"].startswith("SKIP "), out
            assert "unsupported variable format :json" in lines["fmt"], out

            # Exercise both commands' live UID lookup. Layout formatting has
            # its own tests.
            # see: just/grafana.jq.test
            machine.succeed(f"{queries} scratch-promote", timeout=CMD_TIMEOUT)
            out = machine.succeed(
                f"{editor_env} grafana-outline scratch-promote",
                timeout=CMD_TIMEOUT,
            )
            assert out.startswith("# scratch-promote\n"), out
            assert '"Git Sync Test (edited)"' in out, out
    except Exception:
        dump_evidence(EVIDENCE)
        raise
  '';
}
