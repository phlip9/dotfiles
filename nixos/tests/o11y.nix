# NixOS VM test for the phlip9-o11y module.
#
# Single VM with VictoriaMetrics + node-exporter + Grafana.
# Verifies scraping, querying, Grafana datasource provisioning, that
# Grafana's secrets manager encrypts with our key, a Git Sync round trip
# (file -> dashboard -> API save -> file) w/ a `local` repository, and the
# just/grafana-{check,promote}.sh dashboard scripts.
#
# In production, sops-nix provides the secret file paths. Here we
# pass writeText files directly to the module's *File options.
{
  name = "o11y";

  globalTimeout = 600;

  nodes.machine =
    { lib, pkgs, ... }:
    let
      grafanaAdminPassword = "gf-admin-testpwd";
      grafanaAdminPasswordFile = pkgs.writeText "gf-admin-pwd" grafanaAdminPassword;
      grafanaSecretKeyFile = pkgs.writeText "gf-secret-key" "test-secret-key-0123456789abcdef";
      grafanaSecretsManagerKeyFile = pkgs.writeText "gf-secrets-manager-key" "test-secrets-manager-key-0123456789";

      # A just/<name>.sh script as a VM command. The repo script stays the
      # single source of truth; writeShellApplication adds its own shebang.
      justScript =
        name:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [
            pkgs.curl
            pkgs.jq
          ];
          text = lib.removePrefix "#!/usr/bin/env bash\n" (
            builtins.readFile ../../just/${name}.sh
          );
        };
    in
    {
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.sqlite
        (justScript "grafana-check")
        (justScript "grafana-promote")
      ];

      services.phlip9-o11y = {
        enable = true;
        retentionPeriod = "1d";
        grafana.adminPasswordFile = grafanaAdminPasswordFile;
        grafana.secretKeyFile = grafanaSecretKeyFile;
        grafana.secretsManagerKeyFile = grafanaSecretsManagerKeyFile;

        # A `local` repository needs no network or token. Poll at the floor.
        # Default `target = "folder"`: dashboards land in a root folder titled
        # `title`, like `sauna` in prod.
        grafana.gitSync = {
          enable = true;
          title = "machine";
          type = "local";
          local.path = "/var/lib/grafana-git-sync";
          intervalSeconds = 10;
        };
      };

      # Use a fast scrape interval for tests.
      services.victoriametrics.prometheusConfig.global.scrape_interval = "2s";

      # Override admin user for test assertions.
      services.grafana.settings.security.admin_user = "testadmin";

      # The VM has no DNS. Let the throwaway github Repository below pass
      # Git Sync's URL validator, which otherwise resolves the host.
      services.grafana.settings.provisioning.allowed_git_urls = "github.com";
    };

  testScript = ''
    import datetime as dt
    import json
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")

    # VictoriaMetrics starts and responds to health check.
    with subtest("VictoriaMetrics health"):
        machine.wait_for_unit("victoriametrics.service")
        machine.wait_for_open_port(8428)
        machine.succeed("curl -sf http://127.0.0.1:8428/ping")

    # node-exporter starts and serves metrics.
    with subtest("node-exporter health"):
        machine.wait_for_unit("prometheus-node-exporter.service")
        machine.wait_for_open_port(9100)
        machine.succeed(
            "curl -sf -o /dev/null "
            "http://127.0.0.1:9100/metrics"
        )

    # VictoriaMetrics scrapes node-exporter metrics.
    with subtest("VictoriaMetrics scrapes node-exporter"):
        machine.wait_until_succeeds(
            "curl -sf "
            "'http://127.0.0.1:8428/api/v1/query"
            "?query=up%7Bjob%3D%22node-exporter%22%7D' "
            "| jq -e '.data.result[0].value[1] == \"1\"'",
            timeout=30,
        )

    # VictoriaMetrics scrapes itself.
    with subtest("VictoriaMetrics self-scrape"):
        machine.wait_until_succeeds(
            "curl -sf "
            "'http://127.0.0.1:8428/api/v1/query"
            "?query=up%7Bjob%3D%22victoriametrics%22%7D' "
            "| jq -e '.data.result[0].value[1] == \"1\"'",
            timeout=30,
        )

    # Grafana credentials directory exists with secrets.
    with subtest("Grafana LoadCredential"):
        machine.succeed(
            "test -f /run/credentials/"
            "grafana.service/admin-password"
        )
        machine.succeed(
            "test -f /run/credentials/"
            "grafana.service/secret-key"
        )
        machine.succeed(
            "test -f /run/credentials/"
            "grafana.service/secrets-manager-key"
        )

    # Grafana starts and API is accessible.
    with subtest("Grafana health"):
        machine.wait_for_unit("grafana.service")
        machine.wait_for_open_port(3000)
        machine.succeed(
            "curl -sf -u testadmin:gf-admin-testpwd "
            "http://127.0.0.1:3000/api/health "
            "| jq -e '.database == \"ok\"'"
        )

    # Secure values (ex: Git Sync tokens) must get data keys from our
    # secret_key.v2 provider, not the public default secret_key.v1 key.
    # Store a dummy token on a throwaway, read-only github Repository.
    with subtest("Grafana secrets manager encrypts w/ secret_key.v2"):
        repos_url = (
            "http://127.0.0.1:3000/apis/provisioning.grafana.app"
            "/v0alpha1/namespaces/default/repositories"
        )
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
            "curl -sS --fail-with-body -u testadmin:gf-admin-testpwd "
            "-H 'Content-Type: application/json' "
            f"-d {shlex.quote(json.dumps(repo))} {repos_url}"
        )
        providers = machine.succeed(
            # Grafana writes concurrently; wait out its locks.
            "sqlite3 -cmd '.timeout 10000' /var/lib/grafana/data/grafana.db "
            "'SELECT DISTINCT provider FROM secret_data_key'"
        )
        assert providers.strip() == "secret_key.v2", providers
        machine.succeed(
            "curl -sS --fail-with-body -u testadmin:gf-admin-testpwd "
            f"-X DELETE {repos_url}/secrets-test"
        )

    # Provisioned datasource exists.
    with subtest("Grafana datasource provisioned"):
        machine.succeed(
            "curl -sf -u testadmin:gf-admin-testpwd "
            "http://127.0.0.1:3000/api/datasources"
            "/uid/victoriametrics "
            "| jq -e '.name == \"VictoriaMetrics (Plugin)\"'"
        )

    # Grafana can query VictoriaMetrics through datasource.
    with subtest("Grafana queries VictoriaMetrics"):
        machine.wait_until_succeeds(
            "curl -sf -u testadmin:gf-admin-testpwd "
            "'http://127.0.0.1:3000/api/datasources/proxy"
            "/uid/victoriametrics/api/v1/query?query=up' "
            "| jq -e '.data.result | length > 0'",
            timeout=30,
        )

    # Grafana can list available metrics from VictoriaMetrics.
    with subtest("Grafana lists available VictoriaMetrics metrics"):
        machine.wait_until_succeeds(
            "curl -sf -u testadmin:gf-admin-testpwd "
            "'http://127.0.0.1:3000/api/datasources/proxy"
            "/uid/victoriametrics/api/v1/label/__name__/values' "
            "| jq -e '.data | any(index(\"vm_app_version\"))'",
            timeout=30,
        )

    gf_curl = "curl -sS --fail-with-body -u testadmin:gf-admin-testpwd"
    gs_dir = "/var/lib/grafana-git-sync"
    gs_repo_url = f"{repos_url}/dotfiles"
    gs_dash_file = f"{gs_dir}/test-sync.json"
    dashes_url = (
        "http://127.0.0.1:3000/apis/dashboard.grafana.app/v2"
        "/namespaces/default/dashboards"
    )
    dash_url = f"{dashes_url}/test-sync"

    # The setup unit creates our declared Repository, which turns healthy.
    with subtest("Git Sync repository provisioned"):
        machine.wait_for_unit("grafana-git-sync-setup.service")
        machine.succeed(
            f"{gf_curl} {gs_repo_url} | jq -e '"
            ".spec.type == \"local\" "
            "and .spec.sync.target == \"folder\" "
            "and .spec.workflows == [\"write\"]'"
        )
        machine.wait_until_succeeds(
            f"{gf_curl} {gs_repo_url} "
            "| jq -e '.status.health.healthy == true'",
            timeout=60,
        )

    # Grafana never syncs on startup, so the setup unit queues an incremental
    # pull on every start. GET .../jobs lists finished jobs (kept 10 min).
    # Ours is created by the admin (`user:<uid>`), the controller's syncs by
    # `access-policy:provisioning`. The repo dir is still empty: nothing to
    # pull yet.
    with subtest("Git Sync setup triggers a pull on start"):
        machine.succeed(
            "journalctl -o cat -u grafana-git-sync-setup.service "
            "| grep -q 'triggered pull job for repository dotfiles'"
        )
        machine.wait_until_succeeds(
            f"{gf_curl} {gs_repo_url}/jobs | jq -e '.items | any("
            ".spec.action == \"pull\" and .status.state == \"success\" "
            "and (.metadata.annotations[\"grafana.app/createdBy\"] // \"\" "
            "| startswith(\"user:\")))'",
            timeout=60,
        )

    # Re-running the setup unit takes the update (PUT) path, then pulls again.
    with subtest("Git Sync setup is idempotent"):
        machine.succeed("systemctl restart grafana-git-sync-setup.service")
        machine.succeed(
            "journalctl -o cat -u grafana-git-sync-setup.service "
            "| grep -q 'updated repository dotfiles'",
            "journalctl -o cat -u grafana-git-sync-setup.service "
            "| grep -c 'triggered pull job for repository dotfiles' "
            "| grep -qx 2",
        )

    # Number of setup runs that queued a pull, from the setup unit's journal.
    gs_setup_pulls = (
        "journalctl -o cat -u grafana-git-sync-setup.service "
        "| grep -c 'triggered pull job for repository dotfiles'"
    )

    # Setup is wanted by + part of grafana.service, so it re-runs on every
    # Grafana start: restart, stop + start, and Restart= crash recovery.
    with subtest("Git Sync setup re-runs on every Grafana start"):
        setup = "grafana-git-sync-setup.service"
        pulls = int(machine.succeed(gs_setup_pulls))

        machine.succeed("systemctl restart grafana.service")
        machine.wait_for_unit(setup)
        machine.succeed(f"{gs_setup_pulls} | grep -qx {pulls + 1}")

        machine.succeed("systemctl stop grafana.service")
        machine.require_unit_state(setup, "inactive")
        machine.succeed("systemctl start grafana.service")
        machine.wait_for_unit(setup)
        machine.succeed(f"{gs_setup_pulls} | grep -qx {pulls + 2}")

        # `systemctl kill` returns before systemd restarts Grafana, while
        # setup is still active. Wait for the new setup run's pull instead.
        machine.succeed("systemctl kill --signal=KILL grafana.service")
        machine.wait_until_succeeds(
            f"{gs_setup_pulls} | grep -qx {pulls + 3}", timeout=180
        )
        machine.wait_for_unit(setup)
        machine.succeed(
            "systemctl show -P NRestarts grafana.service | grep -qx 1"
        )

    # A minimal v2 dashboard manifest, like nixos/sauna/grafana/*.json.
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

    # A dashboard manifest dropped into the repo dir gets synced in, inside
    # the root folder Git Sync creates w/ uid = repo name, title = repo title.
    # See: pkg/registry/apis/provisioning/resources/id.go RootFolder
    with subtest("Git Sync pulls dashboard into its root folder"):
        machine.succeed(
            f"echo {shlex.quote(json.dumps(dashboard))} > /tmp/test-sync.json",
            "install -o grafana -g grafana -m 0640 "
            f"/tmp/test-sync.json {gs_dash_file}",
        )
        machine.wait_until_succeeds(
            f"{gf_curl} {dash_url} "
            "| jq -e '.spec.title == \"Git Sync Test\"'",
            timeout=150,
        )
        annos = json.loads(
            machine.succeed(f"{gf_curl} {dash_url} | jq .metadata.annotations")
        )
        assert annos["grafana.app/managedBy"] == "repo", annos
        assert annos["grafana.app/managerId"] == "dotfiles", annos
        gs_folder = annos["grafana.app/folder"]
        assert gs_folder == "dotfiles", annos
        machine.succeed(
            f"{gf_curl} http://127.0.0.1:3000/api/folders/{gs_folder} "
            "| jq -e '.title == \"machine\" and .parentUid == null "
            "and .managedBy == \"repo\"'"
        )

    # Saving a repo-managed dashboard through the dashboard API gets
    # re-routed to the repository, i.e. it writes the file. GET + PUT keeps
    # the manager annotations; dropping them would detach the dashboard from
    # the repo instead.
    # See: pkg/storage/unified/apistore/managed.go
    with subtest("Git Sync writes API saves to repository"):
        machine.succeed(
            f"{gf_curl} {dash_url} "
            "| jq '.spec.title = \"Git Sync Test (edited)\"' "
            "> /tmp/edited.json",
            f"{gf_curl} -X PUT -H 'Content-Type: application/json' "
            f"--data-binary @/tmp/edited.json {dash_url}",
        )
        machine.wait_until_succeeds(
            "jq -e '.spec.title == \"Git Sync Test (edited)\"' "
            f"{gs_dash_file}",
            timeout=30,
        )
        machine.succeed(
            f"{gf_curl} {dash_url} "
            "| jq -e '.spec.title == \"Git Sync Test (edited)\"'"
        )

    gf_api = "http://127.0.0.1:3000/api"
    gf_url_env = "GRAFANA_URL=http://127.0.0.1:3000"
    gf_env = (
        f"{gf_url_env} GRAFANA_USER=testadmin GRAFANA_PASSWORD=gf-admin-testpwd"
    )
    json_hdr = "-H 'Content-Type: application/json'"

    # Create a service account w/ `role`, write a new token for it to a file,
    # and return the file path.
    def sa_token(name, role):
        sa = shlex.quote(json.dumps({"name": name, "role": role}))
        sa_id = machine.succeed(
            f"{gf_curl} {json_hdr} -d {sa} {gf_api}/serviceaccounts "
            "| jq -er .id"
        ).strip()
        token = shlex.quote(json.dumps({"name": name}))
        path = f"/tmp/{name}-token"
        machine.succeed(
            f"{gf_curl} {json_hdr} -d {token} "
            f"{gf_api}/serviceaccounts/{sa_id}/tokens | jq -er .key > {path}"
        )
        return path

    # Agents (mcp-grafana) act as an Editor service account.
    editor_token = sa_token("editor", "Editor")
    editor_env = f"{gf_url_env} GRAFANA_TOKEN_FILE={editor_token}"
    machine.succeed(
        "printf 'Authorization: Bearer %s' "
        f"\"$(cat {editor_token})\" > /tmp/editor-auth"
    )
    editor_curl = "curl -sS --fail-with-body -H @/tmp/editor-auth"

    # grafana-check dry-runs a save. The synced dashboard must keep its
    # generation + resourceVersion and the repo file must not change: Git
    # Sync re-routes real saves of repo-managed dashboards into the repo.
    with subtest("grafana-check passes a valid manifest w/o saving"):
        dash_meta = (
            f"{gf_curl} {dash_url} "
            "| jq -c '.metadata | [.generation, .resourceVersion]'"
        )
        dash_file_sum = f"sha256sum {gs_dash_file}"
        before = machine.succeed(dash_meta, dash_file_sum)
        out = machine.succeed(f"{gf_env} grafana-check {gs_dash_file}")
        assert out == f"ok   {gs_dash_file}\n", out
        after = machine.succeed(dash_meta, dash_file_sum)
        assert before == after, (before, after)

    # The server decodes + validates the spec: here a mistyped title, and an
    # empty title on a new name, which dry-runs a create.
    with subtest("grafana-check rejects invalid manifests"):
        machine.succeed(
            f"jq '.spec.title = 42' {gs_dash_file} > /tmp/bad-title.json",
            "jq '.metadata.name = \"no-title\" | .spec.title = \"\"' "
            f"{gs_dash_file} > /tmp/no-title.json",
        )
        status, out = machine.execute(
            f"{gf_env} grafana-check /tmp/bad-title.json "
            f"/tmp/no-title.json {gs_dash_file}"
        )
        print(out)
        lines = out.splitlines()
        assert status == 1, out
        assert lines[0].startswith("FAIL /tmp/bad-title.json: HTTP 400: "), out
        assert "spec.title of type string" in lines[0], out
        assert lines[1].startswith("FAIL /tmp/no-title.json: HTTP 400: "), out
        assert "title cannot be empty" in lines[1], out
        assert lines[2] == f"ok   {gs_dash_file}", out

    # Git Sync gives its root folder default role permissions (only root
    # folders get `grafana.app/grant-permissions`), which the synced dashboards
    # inherit. So the Editor service account can read + dry-run them, no admin.
    # See: pkg/registry/apis/provisioning/resources/folders.go
    with subtest("Editor can access synced dashboards"):
        machine.succeed(
            f"{editor_curl} {dash_url} "
            "| jq -e '.spec.title == \"Git Sync Test (edited)\"'"
        )
        out = machine.succeed(f"{editor_env} grafana-check {gs_dash_file}")
        assert out == f"ok   {gs_dash_file}\n", out
        # Explicit basic auth beats the token file: a bad password fails.
        status, out = machine.execute(
            f"{gf_url_env} GRAFANA_USER=testadmin GRAFANA_PASSWORD=bad "
            f"GRAFANA_TOKEN_FILE={editor_token} grafana-check {gs_dash_file}"
        )
        assert status == 1, out
        assert out.startswith(f"FAIL {gs_dash_file}: HTTP 401"), out

    # The agent's live iteration loop, as the Editor service account: create
    # the Scratch folder (create_folder uses /api/folders, which grants default
    # role permissions), seed an unmanaged copy in it, then patch it (GET +
    # PUT, like update_dashboard).
    with subtest("Editor iterates on a Scratch copy"):
        folder = shlex.quote(json.dumps({"uid": "scratch", "title": "Scratch"}))
        scratch = {
            "apiVersion": "dashboard.grafana.app/v2",
            "kind": "Dashboard",
            "metadata": {
                "name": "scratch-promote",
                "annotations": {"grafana.app/folder": "scratch"},
            },
            "spec": dict(dashboard["spec"], title="Scratch Seed"),
        }
        machine.succeed(
            f"{editor_curl} {json_hdr} -d {folder} {gf_api}/folders",
            f"echo {shlex.quote(json.dumps(scratch))} > /tmp/scratch.json",
            f"{editor_curl} {json_hdr} --data-binary @/tmp/scratch.json "
            f"{dashes_url}",
            f"{editor_curl} {dashes_url}/scratch-promote "
            "| jq '.spec.title = \"Promote <&> Test\"' > /tmp/edit.json",
            f"{editor_curl} -X PUT {json_hdr} --data-binary @/tmp/edit.json "
            f"{dashes_url}/scratch-promote",
        )

    # A full Git Sync pull must leave the Scratch folder + copy alone: Git
    # Sync only manages what it provisioned.
    with subtest("Git Sync pull keeps unmanaged Scratch dashboards"):
        pull = shlex.quote(
            json.dumps({"action": "pull", "pull": {"incremental": False}})
        )
        post_pull = (
            "curl -sS -u testadmin:gf-admin-testpwd -o /tmp/pull-job.json "
            f"-w '%{{http_code}}' {json_hdr} -d {pull} {gs_repo_url}/jobs"
        )

        # Queue our pull. Every pull job is named `<repo>-sync`, so this
        # fails w/ 409 AlreadyExists while a periodic sync (every 10s here)
        # is queued or running. Retry only that, like the setup script.
        # See: pkg/registry/apis/provisioning/jobs/persistentstore.go
        def queue_pull(_last_try):
            status = machine.succeed(post_pull)
            resp = json.loads(machine.succeed("cat /tmp/pull-job.json"))
            if status == "409" and resp.get("reason") == "AlreadyExists":
                return False
            assert status.startswith("2"), (status, resp)
            return True

        retry(queue_pull, timeout=dt.timedelta(seconds=60))

        # GET .../jobs/<uid> only finds a job once it's finished + archived.
        job_uid = machine.succeed(
            "jq -er .metadata.uid /tmp/pull-job.json"
        ).strip()
        job = json.loads(
            machine.wait_until_succeeds(
                f"{gf_curl} {gs_repo_url}/jobs/{job_uid}", timeout=60
            )
        )
        assert job["status"]["state"] == "success", job["status"]
        machine.succeed(
            f"{gf_curl} {dashes_url}/scratch-promote "
            "| jq -e '.metadata.annotations "
            "| .[\"grafana.app/folder\"] == \"scratch\" "
            "and .[\"grafana.app/managedBy\"] == null'",
            f"{gf_curl} {gf_api}/folders/scratch",
            f"{gf_curl} {dash_url}",
        )

    # grafana-promote writes a Scratch copy as a manifest w/ the uid minus its
    # `scratch-` prefix, in Git Sync's on-disk format.
    with subtest("grafana-promote writes a stable manifest"):
        promote = f"{editor_env} grafana-promote"
        promoted = "/tmp/promote/promote.json"
        machine.succeed(
            f"{promote} scratch-promote {promoted}",
            f"cp {promoted} /tmp/promote-first.json",
            # Takes the uid from the existing file now. Same bytes.
            f"{promote} scratch-promote {promoted}",
            f"cmp {promoted} /tmp/promote-first.json",
            # Go-style escaping.
            f"grep -qF '\\u003c\\u0026\\u003e' {promoted}",
        )
        manifest = json.loads(machine.succeed(f"cat {promoted}"))
        assert manifest["apiVersion"] == "dashboard.grafana.app/v2", manifest
        assert manifest["kind"] == "Dashboard", manifest
        assert manifest["metadata"] == {"name": "promote"}, manifest
        assert manifest["spec"]["title"] == "Promote <&> Test", manifest
        assert "status" not in manifest, manifest

        # Explicit uid.
        machine.succeed(
            f"{promote} scratch-promote /tmp/promote/other.json other",
            "jq -e '.metadata.name == \"other\"' /tmp/promote/other.json",
        )

        # Errors.
        status, out = machine.execute(f"{promote} scratch-no /tmp/x.json 2>&1")
        assert status == 1 and "not found" in out, (status, out)
        status, out = machine.execute(f"{promote} 2>&1")
        assert status == 2 and out.startswith("usage:"), (status, out)

    # The promoted manifest passes a dry-run save, which must not create it.
    with subtest("grafana-check dry-runs creates"):
        out = machine.succeed(f"{gf_env} grafana-check {promoted}")
        assert out == f"ok   {promoted}\n", out
        machine.fail(f"{gf_curl} {dashes_url}/promote")
  '';
}
