# End-to-end NixOS VM test for github-agent-authd socket integration.
#
# This test creates a VM with:
# - github-agent-authd socket + service units
# - a fake local GitHub API server
# - local UDS auth checks and token mint/cache verification
{
  name = "github-agent-authd";

  globalTimeout = 90;

  nodes.machine =
    {
      config,
      pkgs,
      ...
    }:
    let
      fakeGitHubAPI = pkgs.writeText "fake-github-api.py" ''
        #!/usr/bin/env python3
        import json
        from datetime import datetime, timedelta, timezone
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from pathlib import Path

        COUNTERS = {
            "install_repo": 0,
            "install_missing": 0,
            "token_mints": 0,
        }

        def write_counters():
            Path("/tmp/fake-gh-install-repo").write_text(
                str(COUNTERS["install_repo"]),
                encoding="utf-8",
            )
            Path("/tmp/fake-gh-install-missing").write_text(
                str(COUNTERS["install_missing"]),
                encoding="utf-8",
            )
            Path("/tmp/fake-gh-token-mints").write_text(
                str(COUNTERS["token_mints"]),
                encoding="utf-8",
            )

        def token_response(token):
            expires_at = (
                datetime.now(timezone.utc) + timedelta(hours=1)
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
            return {"token": token, "expires_at": expires_at}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _fmt, *_args):
                return

            def _auth_ok(self):
                auth = self.headers.get("Authorization", "")
                return auth.startswith("Bearer ")

            def _send_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if not self._auth_ok():
                    self.send_error(401, "missing bearer token")
                    return

                if self.path == "/repos/test/repo/installation":
                    COUNTERS["install_repo"] += 1
                    write_counters()
                    self._send_json(200, {"id": 101})
                    return

                if self.path == "/repos/test/missing/installation":
                    COUNTERS["install_missing"] += 1
                    write_counters()
                    self.send_error(404, "not found")
                    return

                self.send_error(404, "not found")

            def do_POST(self):
                if not self._auth_ok():
                    self.send_error(401, "missing bearer token")
                    return

                if self.path != "/app/installations/101/access_tokens":
                    self.send_error(404, "not found")
                    return

                content_length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(content_length)
                body = json.loads(raw_body.decode("utf-8"))
                repositories = body.get("repositories", [])
                if repositories != ["repo"]:
                    self.send_error(400, "missing repo downscope")
                    return

                COUNTERS["token_mints"] += 1
                write_counters()
                token = f"repo-token-{COUNTERS['token_mints']}"
                self._send_json(201, token_response(token))

        def main():
            write_counters()
            server = ThreadingHTTPServer(("127.0.0.1", 18080), Handler)
            server.serve_forever()

        if __name__ == "__main__":
            main()
      '';
    in
    {
      users.users.testuser = {
        isNormalUser = true;
        extraGroups = [ "github-agent" ];
      };

      users.users.blocked.isNormalUser = true;

      environment.etc."github-agent-app-key.pem".source =
        ./fixtures/github-agent-app-key.pem;

      systemd.services.fake-github-api = {
        description = "Fake GitHub API for github-agent-authd test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${fakeGitHubAPI}";
          Restart = "on-failure";
          RestartSec = 1;
        };
      };

      services.github-agent-authd = {
        enable = true;
        appId = "123456";
        appKeyPath = "/etc/github-agent-app-key.pem";
        githubApiBase = "http://127.0.0.1:18080";
      };
    };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("fake-github-api.service")
    machine.wait_for_unit("github-agent-authd.socket")
    machine.wait_for_file("/run/github-agent-authd/socket")

    # Service should remain inactive until first client request.
    machine.fail("systemctl is-active github-agent-authd.service")

    print("Test 1: socket access denied for non-member user...")
    machine.fail(
        "runuser -u blocked -- "
        "curl --unix-socket /run/github-agent-authd/socket "
        "-fsS http://localhost/healthz"
    )
    print("✓ Test 1 passed")

    print("Test 2: health check via authorized user...")
    machine.succeed(
        "runuser -u testuser -- "
        "curl --unix-socket /run/github-agent-authd/socket "
        "-fsS http://localhost/healthz"
    )
    machine.wait_for_unit("github-agent-authd.service")
    print("✓ Test 2 passed")

    print("Test 3: token retrieval and cache reuse...")
    token1_raw = machine.succeed(
        "runuser -u testuser -- "
        "curl --unix-socket /run/github-agent-authd/socket "
        "-fsS http://localhost/repos/test/repo/token"
    )
    token1 = json.loads(token1_raw)["token"]
    assert token1 == "repo-token-1", f"unexpected token1: {token1}"

    token2_raw = machine.succeed(
        "runuser -u testuser -- "
        "curl --unix-socket /run/github-agent-authd/socket "
        "-fsS http://localhost/repos/test/repo/token"
    )
    token2 = json.loads(token2_raw)["token"]
    assert token2 == "repo-token-1", f"expected cache hit token, got {token2}"

    install_repo = int(machine.succeed("cat /tmp/fake-gh-install-repo").strip())
    token_mints = int(machine.succeed("cat /tmp/fake-gh-token-mints").strip())
    assert install_repo == 1, f"expected 1 install lookup, got {install_repo}"
    assert token_mints == 1, f"expected 1 token mint, got {token_mints}"
    print("✓ Test 3 passed")

    print("Test 4: missing repo uses negative cache...")
    for _ in range(2):
        status = machine.succeed(
            "runuser -u testuser -- "
            "curl --unix-socket /run/github-agent-authd/socket "
            "-s -o /dev/null -w '%{http_code}' "
            "http://localhost/repos/test/missing/token"
        ).strip()
        assert status == "404", f"expected 404, got {status}"

    install_missing = int(
        machine.succeed("cat /tmp/fake-gh-install-missing").strip()
    )
    assert install_missing == 1, (
        "expected missing-installation negative cache hit; "
        f"lookup count was {install_missing}"
    )
    print("✓ Test 4 passed")

    print("✅ All tests passed!")
  '';
}
