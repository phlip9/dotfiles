# NixOS VM test for the o11y (observability) stack.
#
# Single VM with VictoriaMetrics + node-exporter + Grafana.
# Verifies scraping, querying, and Grafana datasource provisioning.
#
# Grafana secrets are injected via systemd LoadCredential and read
# via $__file{} providers.
{
  name = "o11y";

  globalTimeout = 120;

  nodes.machine =
    { pkgs, ... }:
    let
      grafanaAdminPassword = "gf-admin-testpwd";
      grafanaAdminPasswordFile = pkgs.writeText "gf-admin-pwd" grafanaAdminPassword;
      grafanaSecretKey = "gf-secret-testkey-0123456789abcdef";
      grafanaSecretKeyFile = pkgs.writeText "gf-secret-key" grafanaSecretKey;

      # Credentials directory for the grafana.service unit.
      gfCreds = "/run/credentials/grafana.service";
    in
    {
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
      ];

      # -- VictoriaMetrics --
      services.victoriametrics = {
        enable = true;
        listenAddress = "127.0.0.1:8428";
        retentionPeriod = "1d";
        prometheusConfig = {
          global.scrape_interval = "2s";
          scrape_configs = [
            {
              job_name = "victoriametrics";
              static_configs = [
                { targets = [ "127.0.0.1:8428" ]; }
              ];
            }
            {
              job_name = "node-exporter";
              static_configs = [
                { targets = [ "127.0.0.1:9100" ]; }
              ];
            }
          ];
        };
      };

      # -- prometheus-node-exporter --
      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9100;
      };

      # -- Grafana --
      #
      # Secrets are injected via systemd LoadCredential into
      # /run/credentials/grafana.service/, then referenced using
      # Grafana's $__file{path} provider.
      services.grafana = {
        enable = true;
        provision.enable = true;

        settings = {
          analytics.reporting_enabled = false;

          server = {
            http_addr = "127.0.0.1";
            http_port = 3000;
            domain = "localhost";
          };

          security = {
            admin_user = "testadmin";
            admin_password = "$__file{${gfCreds}/admin-password}";
            secret_key = "$__file{${gfCreds}/secret-key}";
          };
        };

        # Provision VictoriaMetrics as a Prometheus-type datasource.
        provision.datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "VictoriaMetrics";
              type = "prometheus";
              access = "proxy";
              uid = "victoriametrics";
              url = "http://127.0.0.1:8428";
              isDefault = true;
              editable = false;
            }
          ];
        };
      };

      # Inject Grafana secrets via LoadCredential.
      systemd.services.grafana.serviceConfig.LoadCredential = [
        "admin-password:${grafanaAdminPasswordFile}"
        "secret-key:${grafanaSecretKeyFile}"
      ];
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
            "test -f /run/credentials/grafana.service/admin-password"
        )
        machine.succeed(
            "test -f /run/credentials/grafana.service/secret-key"
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
            "http://127.0.0.1:3000/api/datasources/uid/victoriametrics "
            "| jq -e '.name == \"VictoriaMetrics\"'"
        )

    # Grafana can query VictoriaMetrics through the datasource.
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
