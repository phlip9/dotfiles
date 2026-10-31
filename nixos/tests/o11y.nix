# NixOS VM test for the phlip9-o11y module.
#
# Single VM with VictoriaMetrics + node-exporter + Grafana.
# Verifies scraping, querying, Grafana datasource provisioning, that
# Grafana's secrets manager encrypts with our key, a Git Sync round trip
# (file -> dashboard -> API save -> file) w/ a `local` repository, and the
# just/grafana-*.sh dashboard scripts.
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

      # The just/grafana-*.sh scripts as VM commands, unmodified: installed
      # side by side (they source grafana-lib.sh + include grafana.jq from
      # their own dir), w/ bin/ wrappers that add curl + jq to PATH.
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
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.sqlite
        grafanaScripts
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

    # Number of setup runs that reached the startup pull: either queued one,
    # or found the controller's sync job already queued (409), which covers
    # it. The repository has a single sync job name, so which one happens
    # depends on timing.
    gs_setup_pulls = (
        "journalctl -o cat -u grafana-git-sync-setup.service "
        "| grep -cE '(triggered pull job|sync job already queued) "
        "for repository dotfiles'"
    )

    # Grafana never syncs on startup, so the setup unit queues an incremental
    # pull on every start. GET .../jobs lists finished jobs (kept 10 min).
    # The repo dir is still empty: nothing to pull yet.
    with subtest("Git Sync setup triggers a pull on start"):
        machine.succeed(f"{gs_setup_pulls} | grep -qx 1")
        machine.wait_until_succeeds(
            f"{gf_curl} {gs_repo_url}/jobs | jq -e '.items | any("
            ".spec.action == \"pull\" and .status.state == \"success\")'",
            timeout=60,
        )

    # Re-running the setup unit takes the update (PUT) path, then pulls again.
    with subtest("Git Sync setup is idempotent"):
        machine.succeed("systemctl restart grafana-git-sync-setup.service")
        machine.succeed(
            "journalctl -o cat -u grafana-git-sync-setup.service "
            "| grep -q 'updated repository dotfiles'",
            f"{gs_setup_pulls} | grep -qx 2",
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

    # The agent's live iteration loop, as the Editor service account:
    # grafana-push creates the Scratch folder (via /api/folders, which grants
    # default role permissions) and seeds an unmanaged copy in it, then the
    # agent patches it (GET + PUT, like update_dashboard).
    with subtest("Editor iterates on a Scratch copy"):
        machine.fail(f"{gf_curl} {gf_api}/folders/scratch")
        seed = dict(dashboard["spec"], title="Scratch Seed")
        out = machine.succeed(
            f"echo {shlex.quote(json.dumps(seed))} > /tmp/promote.json",
            f"{editor_env} grafana-push /tmp/promote.json",
        )
        assert out.endswith("/d/scratch-promote\n"), out
        machine.succeed(
            f"{gf_curl} {gf_api}/folders/scratch "
            "| jq -e '.title == \"Scratch\"'",
            f"{editor_curl} {dashes_url}/scratch-promote "
            "| jq -e '.spec.title == \"Scratch Seed\" "
            "and .metadata.annotations[\"grafana.app/folder\"] == \"scratch\"'",
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

    # grafana-push replaces an existing copy's spec, from a manifest or a bare
    # spec, and refuses anything that could save a Git Sync managed dashboard.
    with subtest("grafana-push replaces Scratch copies, refuses others"):
        push = f"{editor_env} grafana-push"
        title_is = (
            f"{editor_curl} {dashes_url}/scratch-promote "
            "| jq -e --arg t {} '.spec.title == $t'"
        ).format

        # Someone else saves the copy w/ title `title` (like a UI edit).
        def ui_edit(title):
            machine.succeed(
                f"{gf_curl} {dashes_url}/scratch-promote | jq --arg t "
                f"{shlex.quote(title)} '.spec.title = $t' > /tmp/ui-edit.json",
                f"{gf_curl} -X PUT {json_hdr} --data-binary @/tmp/ui-edit.json "
                f"{dashes_url}/scratch-promote",
            )

        # Push a refusal: exits 1 w/ `msg`.
        def refused(args, msg):
            status, out = machine.execute(f"{push} {args} 2>&1")
            assert status == 1 and msg in out, (args, status, out)

        # The promoted file, edited in place: its baseline matches.
        machine.succeed(
            f"jq '.spec.title = \"Pushed\"' {promoted} > /tmp/edit.json",
            f"mv /tmp/edit.json {promoted}",
            f"{push} {promoted} scratch-promote",
            title_is("Pushed"),
        )
        # Another file (a bare spec) has no baseline: only w/ --force.
        machine.succeed(f"jq '.spec' {gs_dash_file} > /tmp/bare.json")
        refused("/tmp/bare.json scratch-promote", "never pushed/promoted")
        machine.succeed(
            f"{push} --force /tmp/bare.json scratch-promote",
            title_is("'Git Sync Test (edited)'"),
        )
        # Someone else saved the copy since: refused, also after pulling it
        # into another file, which doesn't vouch for this one.
        ui_edit("UI Edit")
        refused("/tmp/bare.json scratch-promote", "changed since our last push")
        machine.succeed(
            f"{editor_env} grafana-promote scratch-promote /tmp/pulled.json"
        )
        refused("/tmp/bare.json scratch-promote", "changed since our last push")
        # Editing the pulled file in place + pushing it works.
        machine.succeed(
            "jq '.spec.title = \"Pulled\"' /tmp/pulled.json > /tmp/edit.json",
            "mv /tmp/edit.json /tmp/pulled.json",
            f"{push} /tmp/pulled.json scratch-promote",
            title_is("Pulled"),
        )
        # --force discards someone else's save.
        ui_edit("UI Edit 2")
        machine.succeed(
            f"{push} --force /tmp/bare.json scratch-promote",
            title_is("'Git Sync Test (edited)'"),
        )
        # No `scratch-` prefix, ex: the synced dashboard's own uid.
        status, out = machine.execute(f"{push} {gs_dash_file} test-sync 2>&1")
        assert status == 1 and "no scratch- prefix" in out, (status, out)
        # `scratch-` uids outside the Scratch folder: in another folder the
        # Editor can read (refused by the folder check), and in the root
        # folder, which Editors can't even read (refused w/ the GET's 403).
        machine.succeed(
            f"{gf_curl} {json_hdr} "
            "-d '{\"uid\": \"other\", \"title\": \"Other\"}' "
            f"{gf_api}/folders"
        )
        for name, folder in [("in-other", "other"), ("in-root", None)]:
            meta = {"name": f"scratch-{name}"}
            if folder:
                meta["annotations"] = {"grafana.app/folder": folder}
            elsewhere = {
                "apiVersion": "dashboard.grafana.app/v2",
                "kind": "Dashboard",
                "metadata": meta,
                "spec": dict(dashboard["spec"], title="Elsewhere"),
            }
            machine.succeed(
                f"echo {shlex.quote(json.dumps(elsewhere))} > /tmp/else.json",
                f"{gf_curl} {json_hdr} --data-binary @/tmp/else.json "
                f"{dashes_url}",
            )
            status, out = machine.execute(
                f"{push} /tmp/bare.json scratch-{name} 2>&1"
            )
            assert status == 1, (name, status, out)
            if folder:
                assert "refusing to overwrite" in out, (name, out)
            machine.succeed(
                f"{gf_curl} {dashes_url}/scratch-{name} "
                "| jq -e '.spec.title == \"Elsewhere\"'"
            )
        # Not a v2 spec.
        status, out = machine.execute(
            f"echo '{{}}' > /tmp/empty.json; {push} /tmp/empty.json 2>&1"
        )
        assert status == 1 and "not a v2 dashboard spec" in out, (status, out)

    # grafana-queries runs each panel query through /api/ds/query w/ the
    # datasource variable resolved + other variables substituted, and reports
    # ok / EMPTY / FAIL per query.
    with subtest("grafana-queries runs panel queries"):

        # A v2 timeseries panel `key` w/ PromQL `exprs`.
        def panel(key, exprs):
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
                        "spec": {"queries": queries},
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
                    "spec": {"name": "job", "current": {"value": ["$__all"]}},
                },
                # Custom All value: matches no job.
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
                "good": panel("good", [
                    'up{job=~"$job"}',
                    "rate(vm_http_requests_total[$__rate_interval])",
                ]),
                "empty": panel("empty", ["no_such_metric"]),
                "bad": panel("bad", ["up{"]),
                "allvalue": panel("allvalue", ['up{job=~"$nojob"}']),
                "fmt": panel("fmt", ['up{job=~"''${job:json}"}']),
            },
            "layout": {"kind": "GridLayout", "spec": {"items": []}},
        }
        machine.succeed(
            f"echo {shlex.quote(json.dumps(spec))} > /tmp/queries.json"
        )
        queries = f"{editor_env} grafana-queries --from now-5m"
        status, out = machine.execute(f"{queries} /tmp/queries.json")
        print(out)
        assert status == 1, out
        lines = {line.split()[1]: line for line in out.splitlines()[1:]}
        assert lines["bad/A"].startswith("FAIL "), out
        assert lines["empty/A"].startswith("EMPTY "), out
        assert lines["good/A"].startswith("ok "), out
        assert lines["good/B"].startswith("ok "), out
        assert lines["allvalue/A"].startswith("EMPTY "), out
        assert lines["fmt"].startswith("SKIP "), out
        assert "unsupported variable format :json" in lines["fmt"], out

        # Only good queries: exit 0. Also takes a server uid.
        machine.succeed(
            "jq 'del(.elements.bad)' /tmp/queries.json > /tmp/queries-ok.json",
            f"{queries} /tmp/queries-ok.json",
            f"{queries} scratch-promote",
        )
  '';
}
