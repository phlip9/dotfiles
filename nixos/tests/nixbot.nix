# nixbot + niks3 NixOS integration test. Run against a fake GitHub API and S3
# cache backend.
#
# TODO(phlip9): use our phlip9-nixbot-ci module
{
  name = "nixbot";
  nodes = {
    github =
      { self, pkgs, ... }:
      let
        fakeGithubPort = 8970;
        fakeGithub = pkgs.writers.writePython3Bin "fake-github" { } ''
          import json
          import re
          from http.server import BaseHTTPRequestHandler, HTTPServer

          CHECK_RUNS_LOG = "/var/lib/fake-github/check_runs.jsonl"

          REPO = {
              "id": 1,
              "name": "test-flake",
              "owner": {"login": "acme"},
              "default_branch": "master",
              "clone_url": "file:///var/lib/test-repo",
              "private": False,
              "topics": ["build-with-buildbot"],
          }


          class Handler(BaseHTTPRequestHandler):
              def _json(self, payload, code=200):
                  body = json.dumps(payload).encode()
                  self.send_response(code)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)

              def do_GET(self):
                  path = self.path.split("?")[0]
                  if path == "/app/installations":
                      self._json([{"id": 1}])
                  elif path == "/installation/repositories":
                      self._json({"repositories": [REPO]})
                  elif path == "/repos/acme/test-flake/pulls":
                      # Reconciliation polls open PRs; none exist here.
                      self._json([])
                  else:
                      self._json({"message": "not found"}, 404)

              def do_PATCH(self):
                  length = int(self.headers.get("Content-Length") or 0)
                  body = self.rfile.read(length)
                  path = self.path.split("?")[0]
                  if re.fullmatch(r"/repos/acme/test-flake/check-runs/[0-9]+", path):
                      entry = json.loads(body)
                      with open(CHECK_RUNS_LOG, "a") as f:
                          f.write(json.dumps(entry) + "\n")
                      self._json({"id": int(path.rsplit("/", 1)[1])}, 200)
                  else:
                      self._json({"message": "not found"}, 404)

              def do_POST(self):
                  length = int(self.headers.get("Content-Length") or 0)
                  body = self.rfile.read(length)
                  path = self.path.split("?")[0]
                  if re.fullmatch(r"/app/installations/1/access_tokens", path):
                      self._json({"token": "fake-token"}, 201)
                  elif path == "/repos/acme/test-flake/check-runs":
                      entry = json.loads(body)
                      # The poster stores this id to PATCH the run on
                      # completion; key it by name so each check keeps a
                      # distinct id like the real API.
                      check_run_id = abs(hash(entry["name"])) % 1_000_000
                      with open(CHECK_RUNS_LOG, "a") as f:
                          f.write(json.dumps(entry) + "\n")
                      self._json({"id": check_run_id}, 201)
                  else:
                      self._json({"message": "not found"}, 404)

              def log_message(self, fmt, *args):
                  pass


          HTTPServer(("127.0.0.1", ${toString fakeGithubPort}), Handler).serve_forever()
        '';
      in
      {
        imports = [ ];

        services.nixbot = {
          enable = true;
          domain = "localhost";
          nginx.enable = false;
          github = {
            enable = true;
            appId = 123;
            apiUrl = "http://127.0.0.1:${toString fakeGithubPort}";
            appSecretKeyFile = "/var/lib/secrets/github-app-key.pem";
            webhookSecretFile = pkgs.writeText "webhook-secret" "test-webhook-secret";
          };
        };

        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

        environment.systemPackages = [
          pkgs.git
          pkgs.curl
          pkgs.jq
        ];

        systemd.services.fake-github = {
          wantedBy = [ "multi-user.target" ];
          before = [ "nixbot.service" ];
          requiredBy = [ "nixbot.service" ];
          serviceConfig = {
            ExecStart = "${fakeGithub}/bin/fake-github";
            StateDirectory = "fake-github";
          };
        };

        systemd.services.setup-test-repo = {
          wantedBy = [ "multi-user.target" ];
          before = [ "nixbot.service" ];
          requiredBy = [ "nixbot.service" ];
          path = [
            pkgs.git
            pkgs.openssl
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            mkdir -p /var/lib/secrets
            openssl genrsa -out /var/lib/secrets/github-app-key.pem 2048
            chmod 644 /var/lib/secrets/github-app-key.pem

            rm -rf /var/lib/test-repo /tmp/test-flake

            # setupTestFlake - build a minimal test flake with one check
            mkdir -p /tmp/test-flake
            cd /tmp/test-flake
            git init -b master
            git config user.name test
            git config user.email test@example.com
            cat > flake.nix <<'EOF'
            {
              outputs = { self }: {
                checks.x86_64-linux.test = derivation {
                  name = "test";
                  system = "x86_64-linux";
                  builder = "/bin/sh";
                  args = [ "-c" "echo hello > $out" ];
                };
              };
            }
            EOF
            git add flake.nix
            git commit -m "initial commit"

            git clone --bare /tmp/test-flake /var/lib/test-repo
            chmod -R a+rX /var/lib/test-repo
          '';
        };
      };
  };

  testScript = ''
    import hashlib
    import hmac
    import json
    import shlex

    start_all()

    with subtest("github: nixbot becomes healthy"):
        github.wait_for_unit("nixbot.service")
        github.wait_until_succeeds(
            "curl --fail -s http://127.0.0.1:8010/health", timeout=120
        )

    with subtest("github: project discovered from fake forge"):
        def github_project_discovered(_ignore):
            out = github.succeed("curl --fail -s http://127.0.0.1:8010/api/repos")
            projects = json.loads(out)
            print(projects)
            return any(
                p["owner"] == "acme" and p["name"] == "test-flake"
                for p in projects
            )

        retry(github_project_discovered, timeout_seconds=120)

    with subtest("github: webhook push triggers eval, build, and statuses"):
        sha = github.succeed("git -C /var/lib/test-repo rev-parse master").strip()
        body = json.dumps({
            "ref": "refs/heads/master",
            "after": sha,
            "repository": {"id": 1, "default_branch": "master"},
            "head_commit": {"message": "initial commit"},
        }).encode()
        sig = hmac.new(b"test-webhook-secret", body, hashlib.sha256).hexdigest()
        github.succeed(
            "curl --fail -s -X POST http://127.0.0.1:8010/webhooks/github "
            "-H 'Content-Type: application/json' "
            "-H 'X-GitHub-Event: push' "
            "-H 'X-GitHub-Delivery: test-delivery-1' "
            f"-H 'X-Hub-Signature-256: sha256={sig}' "
            f"-d {shlex.quote(body.decode())}"
        )

        def github_checks_posted(_ignore):
            out = github.execute("cat /var/lib/fake-github/check_runs.jsonl")[1]
            check_runs = [json.loads(line) for line in out.splitlines() if line]
            print(check_runs)
            done = {
                cr["name"]: cr.get("conclusion")
                for cr in check_runs
                if cr.get("status") == "completed"
            }
            return (
                done.get("nixbot/nix-eval") == "success"
                and done.get("nixbot/nix-build") == "success"
            )

        retry(github_checks_posted, timeout_seconds=300)
  '';
}
