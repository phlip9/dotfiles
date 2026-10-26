# NixOS VM test for the phlip9-o11y module.
#
# Single VM with VictoriaMetrics + node-exporter + Grafana.
# Verifies scraping, querying, Grafana datasource provisioning, that
# Grafana's secrets manager encrypts with our key, and a Git Sync round trip
# (file -> dashboard -> API save -> file) w/ a `local` repository.
#
# In production, sops-nix provides the secret file paths. Here we
# pass writeText files directly to the module's *File options.
{
  name = "o11y";

  globalTimeout = 600;

  nodes.machine =
    { pkgs, ... }:
    let
      grafanaAdminPassword = "gf-admin-testpwd";
      grafanaAdminPasswordFile = pkgs.writeText "gf-admin-pwd" grafanaAdminPassword;
      grafanaSecretKeyFile = pkgs.writeText "gf-secret-key" "test-secret-key-0123456789abcdef";
      grafanaSecretsManagerKeyFile = pkgs.writeText "gf-secrets-manager-key" "test-secrets-manager-key-0123456789";
    in
    {
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.sqlite
      ];

      services.phlip9-o11y = {
        enable = true;
        retentionPeriod = "1d";
        grafana.adminPasswordFile = grafanaAdminPasswordFile;
        grafana.secretKeyFile = grafanaSecretKeyFile;
        grafana.secretsManagerKeyFile = grafanaSecretsManagerKeyFile;

        # A `local` repository needs no network or token. Poll at the floor.
        grafana.gitSync = {
          enable = true;
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
            "and .spec.sync.target == \"folderless\" "
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

    # A dashboard manifest dropped into the repo dir gets synced in.
    with subtest("Git Sync pulls dashboard from repository"):
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
        machine.succeed(
            f"{gf_curl} {dash_url} | jq -e '.metadata.annotations "
            "| .[\"grafana.app/managedBy\"] == \"repo\" "
            "and .[\"grafana.app/managerId\"] == \"dotfiles\"'"
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
  '';
}
