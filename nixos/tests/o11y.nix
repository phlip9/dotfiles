# NixOS VM test for the o11y (observability) stack.
#
# Single VM with VictoriaMetrics + node-exporter + Grafana.
# Verifies scraping, querying, and Grafana datasource provisioning.
{
  name = "o11y";

  globalTimeout = 120;

  nodes.machine =
    { pkgs, ... }:
    let
      # Use file provider to avoid plaintext passwords in the Nix store.
      adminPassword = "testpassword";
      adminPasswordFile = pkgs.writeText "grafana-pwd" adminPassword;
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
            admin_password = "$__file{${adminPasswordFile}}";
            secret_key = "testsecretkey0123456789";
          };
        };

        # Provision VictoriaMetrics as a Prometheus-type datasource
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
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # 1. VictoriaMetrics starts and responds to health check.
    with subtest("VictoriaMetrics health"):
        machine.wait_for_unit("victoriametrics.service")
        machine.wait_for_open_port(8428)
        machine.succeed("curl -sf http://127.0.0.1:8428/ping")

    # 2. node-exporter starts and serves metrics.
    with subtest("node-exporter health"):
        machine.wait_for_unit("prometheus-node-exporter.service")
        machine.wait_for_open_port(9100)
        machine.succeed(
            "curl -sf -o /dev/null http://127.0.0.1:9100/metrics"
        )

    # 3. VictoriaMetrics scrapes node-exporter metrics.
    #    Wait for at least one scrape cycle (2s interval).
    with subtest("VictoriaMetrics scrapes node-exporter"):
        machine.wait_until_succeeds(
            "curl -sf 'http://127.0.0.1:8428/api/v1/query?query=up%7Bjob%3D%22node-exporter%22%7D' "
            "| jq -e '.data.result[0].value[1] == \"1\"'",
            timeout=30,
        )

    # 4. VictoriaMetrics scrapes itself.
    with subtest("VictoriaMetrics self-scrape"):
        machine.wait_until_succeeds(
            "curl -sf 'http://127.0.0.1:8428/api/v1/query?query=up%7Bjob%3D%22victoriametrics%22%7D' "
            "| jq -e '.data.result[0].value[1] == \"1\"'",
            timeout=30,
        )

    # 5. Grafana starts and API is accessible.
    with subtest("Grafana health"):
        machine.wait_for_unit("grafana.service")
        machine.wait_for_open_port(3000)
        machine.succeed(
            "curl -sf -u testadmin:testpassword "
            "http://127.0.0.1:3000/api/health | jq -e '.database == \"ok\"'"
        )

    # 6. Provisioned datasource exists and is healthy.
    with subtest("Grafana datasource provisioned"):
        machine.succeed(
            "curl -sf -u testadmin:testpassword "
            "http://127.0.0.1:3000/api/datasources/uid/victoriametrics "
            "| jq -e '.name == \"VictoriaMetrics\"'"
        )

    # 7. Grafana can query VictoriaMetrics through the datasource.
    with subtest("Grafana queries VictoriaMetrics"):
        machine.wait_until_succeeds(
            "curl -sf -u testadmin:testpassword "
            "'http://127.0.0.1:3000/api/datasources/proxy/uid/victoriametrics"
            "/api/v1/query?query=up' "
            "| jq -e '.data.result | length > 0'",
            timeout=30,
        )
  '';
}
