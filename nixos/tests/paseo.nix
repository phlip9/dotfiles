# End-to-end NixOS VM test for the Paseo daemon, relay, and nginx wiring.
{
  name = "paseo";

  globalTimeout = 300;

  nodes.machine =
    { config, pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.paseo = {
        enable = true;
        relay = {
          enable = true;
          mode = "remote";
          host = "[::1]";
          port = 8411;
          publicEndpoint = "relay.test:80";
          useTls = false;
          publicUseTls = false;
        };
        relayServer = {
          enable = true;
          domain = "relay.test";
        };
        webUi = {
          enable = true;
          domain = "paseo.test";
          publicBaseUrl = "http://paseo.test";
        };
        auth.passwordFile = config.sops.secrets.paseo-daemon-password.path;
        hostnames = [
          "paseo.test"
        ];
        nginx = {
          forceSSL = false;
          enableACME = false;
        };
      };
      sops.secrets.paseo-daemon-password = { };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("relay starts and reports health"):
        machine.wait_for_unit("paseo-relay.service")
        machine.succeed(
            "curl -g -sf http://[::1]:8411/health "
            "| jq -e '.status == \"ok\" and .version == \"v0.5.0\"'"
        )

    with subtest("daemon starts and reports health"):
        machine.wait_for_unit("paseo.service")
        machine.succeed(
            "systemctl show paseo.service -p ExecStart --value "
            "| grep -E 'bash.*-lc'"
        )
        machine.succeed(
            "test -f /run/credentials/paseo.service/daemon-password"
        )
        machine.succeed(
            "pid=$(systemctl show paseo.service -p MainPID --value); "
            "tr '\\0' '\\n' < /proc/$pid/environ "
            "| grep '^PASEO_PASSWORD_FILE=/run/credentials/paseo.service/daemon-password$'"
        )
        machine.fail(
            "pid=$(systemctl show paseo.service -p MainPID --value); "
            "tr '\\0' '\\n' < /proc/$pid/environ "
            "| grep '^PASEO_PASSWORD='"
        )
        machine.succeed("curl -g -sf http://[::1]:6767/api/health")
        machine.succeed(
            "test \"$(curl -g -s -o /dev/null -w '%{http_code}' "
            "http://[::1]:6767/api/status)\" = 401"
        )
        machine.succeed(
            "curl -g -sf -H 'Authorization: Bearer correct-password' "
            "http://[::1]:6767/api/status "
            "| jq -e '.status == \"server_info\"'"
        )

    with subtest("bundled web UI is served"):
        machine.wait_until_succeeds(
            "curl -g -sf -H 'Host: paseo.test' http://[::1]:6767/ "
            "| grep -i '<html'",
            timeout=30,
        )

    with subtest("nginx proxies web UI"):
        machine.wait_for_unit("nginx.service")
        machine.wait_for_open_port(80)
        machine.succeed(
            "curl -sf -H 'Host: paseo.test' http://127.0.0.1/ "
            "| grep -i '<html'"
        )

    with subtest("nginx proxies relay health"):
        machine.succeed(
            "curl -sf -H 'Host: relay.test' http://127.0.0.1/health "
            "| jq -e '.status == \"ok\"'"
        )
  '';
}
