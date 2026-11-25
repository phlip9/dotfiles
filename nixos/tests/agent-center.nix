# NixOS container test for the agent-center module's wiring.
#
#   curl --http--> nginx --auth_request--> oauth2-proxy (htpasswd basic auth)
#                    \--Host/Origin rewrite--> stub agent-center-server
#   curl as alice / nobody / root --loopback, owner match--^
#
# The real server is private (see nixos/mods/agent-center.nix), so a stub
# that echoes each request's method, Host, and Origin stands in for it. GitHub
# login can't run offline; oauth2-proxy's htpasswd basic auth passes the same
# `auth_request` instead.
#
# Verifies the loopback owner match (incl. across firewall reloads), the
# hardened unit's env, the auth redirect, and the Host/Origin rewrite.
{
  name = "agent-center";

  globalTimeout = 300;

  containers.machine =
    {
      lib,
      phlipPkgs,
      pkgs,
      ...
    }:
    let
      # Echoes each request as JSON. Stands in for `agent-center-server serve`.
      stubServer = phlipPkgs.writeTypedPython3Bin "agent-center-server" { } ''
        import json
        import os
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def _echo(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                self.rfile.read(length)
                body = json.dumps(
                    {
                        "method": self.command,
                        "path": self.path,
                        "host": self.headers.get("Host"),
                        "origin": self.headers.get("Origin"),
                        "human": os.environ.get("AGENT_CENTER_HUMAN_NAME"),
                        "paseo_home": os.environ.get("PASEO_HOME"),
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            do_GET = _echo
            do_POST = _echo


        host, port = os.environ["AGENT_CENTER_ADDR"].rsplit(":", 1)
        ThreadingHTTPServer((host, int(port)), Handler).serve_forever()
      '';

      htpasswd = pkgs.runCommand "agent-center-htpasswd" {
        nativeBuildInputs = [ pkgs.apacheHttpd ];
      } "htpasswd -nbB alice alice-password > $out";
    in
    {
      users.users.alice = {
        isNormalUser = true;
        uid = 1001;
      };
      systemd.tmpfiles.rules = [ "d /home/alice/paseo 0700 alice users -" ];

      services.agent-center = {
        enable = true;
        user = "alice";
        humanName = "Alice";
        domain = "agent-center.test";
        # The stub, in place of the mutable profile.
        profile = "${stubServer}";
        paseoHome = "/home/alice/paseo";
        paseoPackage = pkgs.writeShellScriptBin "paseo" "exit 1";
      };

      services.nginx.virtualHosts."agent-center.test" = {
        forceSSL = lib.mkForce false;
        enableACME = lib.mkForce false;
      };

      services.oauth2-proxy = {
        enable = true;
        provider = "github";
        clientID = "test-client-id";
        clientSecretFile = pkgs.writeText "client-secret" "test-client-secret";
        cookie.secretFile = pkgs.writeText "cookie-secret" "0123456789abcdef";
        email.domains = [ "*" ];
        htpasswd.file = "${htpasswd}";
        extraConfig.github-user = "alice";
      };

      # sops isn't under test.
      services.openssh.enable = lib.mkForce false;
    };

  testScript = ''
    import json

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        CURL_QUIET,
        dump_evidence,
        wait_for_cmd,
    )

    EVIDENCE = [
        "systemctl status agent-center oauth2-proxy nginx --no-pager",
        "journalctl --no-pager -o cat -u agent-center -u oauth2-proxy"
        " -u nginx | tail -n 50",
        "iptables -S OUTPUT; iptables -S agent-center-lo",
        "ss -Hltn",
    ]

    LOOPBACK = "http://127.0.0.1:4400/"
    VHOST = "-H 'Host: agent-center.test' http://127.0.0.1/api/x"
    CODE = "-o /dev/null -w '%{http_code}'"
    CODE_LOC = "-o /dev/null -w '%{http_code} %{redirect_url}'"
    AUTH = "-u alice:alice-password"


    def curl_as(user: str, args: str) -> tuple[int, str]:
        return machine.execute(
            f"runuser -u {user} -- {CURL} {args}", timeout=CMD_TIMEOUT
        )


    def echo(args: str) -> dict[str, str | None]:
        out = machine.succeed(f"{CURL} -f {args}", timeout=CMD_TIMEOUT)
        return json.loads(out)


    def assert_owner_match() -> None:
        rc, out = curl_as("alice", LOOPBACK)
        assert rc == 0, (rc, out)
        assert json.loads(out)["host"] == "127.0.0.1:4400", out
        for user in ("nobody", "root"):
            rc, out = curl_as(user, LOOPBACK)
            # 7: couldn't connect (the SYN got a reset)
            assert rc == 7, (user, rc, out)


    try:
        machine.wait_for_unit("agent-center.service")
        # Root is refused, so poll as alice.
        wait_for_cmd(machine, f"runuser -u alice -- {CURL_QUIET} {LOOPBACK}")

        with subtest("unit env"):
            rc, out = curl_as("alice", LOOPBACK)
            assert rc == 0, (rc, out)
            resp = json.loads(out)
            assert resp["human"] == "Alice", resp
            assert resp["paseo_home"] == "/home/alice/paseo", resp

        with subtest("only alice and nginx reach the listener"):
            assert_owner_match()

        with subtest("firewall reload keeps one rule"):
            machine.succeed("systemctl reload firewall", timeout=CMD_TIMEOUT)
            jumps = machine.succeed(
                "iptables -S OUTPUT | grep -c agent-center-lo"
            )
            assert jumps.strip() == "1", jumps
            assert_owner_match()

        machine.wait_for_unit("oauth2-proxy.service")
        machine.wait_for_unit("nginx.service")

        with subtest("no login redirects to oauth2-proxy"):
            code_loc = machine.succeed(
                f"{CURL} {CODE_LOC} {VHOST}",
                timeout=CMD_TIMEOUT,
            )
            code, loc = code_loc.split(" ", 1)
            assert code == "307", code_loc
            login = "https://agent-center.test/oauth2/start?"
            assert loc.startswith(login), loc

        with subtest("wrong password is refused"):
            code = machine.succeed(
                f"{CURL} {CODE} -u alice:nope {VHOST}",
                timeout=CMD_TIMEOUT,
            )
            assert code == "307", code

        with subtest("Host is rewritten to the loopback listener"):
            resp = echo(f"{AUTH} {VHOST}")
            assert resp["host"] == "127.0.0.1:4400", resp
            assert resp["origin"] is None, resp

        with subtest("our Origin maps to the loopback one; others pass"):
            ours = "-H 'Origin: https://agent-center.test'"
            resp = echo(f"{AUTH} -X POST {ours} {VHOST}")
            assert resp["origin"] == "http://127.0.0.1:4400", resp
            evil = "-H 'Origin: https://evil.test'"
            resp = echo(f"{AUTH} -X POST {evil} {VHOST}")
            assert resp["origin"] == "https://evil.test", resp
    except Exception:
        dump_evidence([(machine, EVIDENCE)])
        raise
  '';
}
