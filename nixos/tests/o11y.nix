# NixOS VM test for the phlip9-o11y module.
#
# Single VM with VictoriaMetrics + node-exporter + Grafana.
# Verifies scraping, querying, and Grafana datasource provisioning.
#
# In production, sops-nix provides the secret file paths. Here we
# pass writeText files directly to the module's *File options.
{
  name = "o11y";

  globalTimeout = 120;

  nodes.machine =
    { pkgs, ... }:
    let
      grafanaAdminPassword = "gf-admin-testpwd";
      grafanaAdminPasswordFile = pkgs.writeText "gf-admin-pwd" grafanaAdminPassword;
      grafanaSecretKeyFile = pkgs.writeText "gf-secret-key" "test-secret-key-0123456789abcdef";
    in
    {
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
      ];

      services.phlip9-o11y = {
        enable = true;
        retentionPeriod = "1d";
        grafana.adminPasswordFile = grafanaAdminPasswordFile;
        grafana.secretKeyFile = grafanaSecretKeyFile;
      };

      # Use a fast scrape interval for tests.
      services.victoriametrics.prometheusConfig.global.scrape_interval = "2s";

      # Override admin user for test assertions.
      services.grafana.settings.security.admin_user = "testadmin";
    };

  testScript = ''
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

    # Grafana starts and API is accessible.
    with subtest("Grafana health"):
        machine.wait_for_unit("grafana.service")
        machine.wait_for_open_port(3000)
        machine.succeed(
            "curl -sf -u testadmin:gf-admin-testpwd "
            "http://127.0.0.1:3000/api/health "
            "| jq -e '.database == \"ok\"'"
        )

    # Provisioned datasource exists.
    with subtest("Grafana datasource provisioned"):
        machine.succeed(
            "curl -sf -u testadmin:gf-admin-testpwd "
            "http://127.0.0.1:3000/api/datasources"
            "/uid/victoriametrics "
            "| jq -e '.name == \"VictoriaMetrics\"'"
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
  '';
}
