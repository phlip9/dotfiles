# phlip9-nixbot-ci integration test
#
# - fake GitHub API advertises a local test repo and records check runs
# - signed push webhook triggers nixbot eval and build
# - niks3 post-build step uploads the output
# - niks3 server writes signed cache objects to S3 (local RustFS S3 API in test)
# - reads the output's narinfo directly from S3, verifies its signature, and
#   copies the output into an empty Nix store
let
  apiToken = "test-token-that-is-at-least-36-characters-long";
  s3AccessKey = "rustfsadmin";
  s3SecretKey = "rustfsadmin";
  s3Bucket = "nixbot-test";
  signingPublicKey = "niks3-test-1:f/Mfq81CcfUlnchjlZdtSGyZUHplChuNKltk08qxPvs=";
in
{
  name = "nixbot";
  nodes = {
    github =
      { lib, pkgs, ... }:
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
        services.phlip9-nixbot-ci = {
          enable = true;
          domain = "localhost";
          admins = [ "github:acme" ];

          nginx = {
            enableACME = false;
          };

          github = {
            appId = 123;
            apiUrl = "http://127.0.0.1:${toString fakeGithubPort}";
            oauthClientId = "test-oauth-client";
            userAllowlist = [ "acme" ];
            topic = "build-with-buildbot";
          };

          cache = {
            url = "http://localhost:5751";
            publicKey = signingPublicKey;
            s3 = {
              endpoint = "127.0.0.1:9000";
              bucket = s3Bucket;
              useSSL = false;
            };
          };
        };

        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
        nix.settings.trusted-public-keys = [ signingPublicKey ];

        environment.systemPackages = [
          pkgs.git
          pkgs.curl
          pkgs.jq
          pkgs.openssl
          pkgs.s5cmd
          pkgs.zstd
        ];

        # RustFS replaces Cloudflare R2 while retaining the real S3 protocol
        # boundary used by niks3 in production.
        systemd.services.rustfs = {
          description = "RustFS S3-compatible object storage";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              "${pkgs.rustfs}/bin/rustfs"
              "--address"
              "127.0.0.1:9000"
              "--access-key"
              s3AccessKey
              "--secret-key"
              s3SecretKey
              "/var/lib/rustfs"
            ];
            StateDirectory = "rustfs";
            DynamicUser = true;
            Restart = "on-failure";
          };
        };

        # Create the bucket before niks3 opens its S3-backed store.
        systemd.services.rustfs-setup = {
          description = "Create the nixbot test S3 bucket";
          after = [ "rustfs.service" ];
          requires = [ "rustfs.service" ];
          before = [ "niks3.service" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            S3_ENDPOINT_URL = "http://127.0.0.1:9000";
            AWS_ACCESS_KEY_ID = s3AccessKey;
            AWS_SECRET_ACCESS_KEY = s3SecretKey;
          };
          path = [ pkgs.s5cmd ];
          script = ''
            set -euo pipefail

            # Wait for the object store API before creating the cache bucket.
            for attempt in $(seq 60); do
              if s5cmd ls >/dev/null 2>&1; then
                s5cmd mb s3://${s3Bucket} || true
                exit 0
              fi
              sleep 1
            done

            echo "RustFS did not become ready" >&2
            exit 1
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };

        systemd.services.niks3 = {
          after = [ "rustfs-setup.service" ];
          requires = [ "rustfs-setup.service" ];
        };

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
          path = [ pkgs.git ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
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

    # Exercise the same nginx-to-Unix-socket boundary used in production.
    nixbot_url = "http://localhost"

    start_all()

    with subtest("secrets: sops decrypts the nixbot CI fixture"):
        github.wait_until_succeeds(
            "test -r /run/secrets/nixbot-github-app-secret-key"
        )
        github.succeed(
            "test \"$(cat /run/secrets/niks3-api-token)\" = "
            "'${apiToken}'"
        )
        github.succeed(
            "openssl pkey -in "
            "/run/secrets/nixbot-github-app-secret-key -noout"
        )

    with subtest("cache: RustFS and niks3 become healthy"):
        github.wait_for_unit("rustfs-setup.service")
        github.wait_for_unit("niks3.service")
        github.wait_until_succeeds(
            "curl --noproxy '*' --fail -g -s 'http://[::1]:5751/health'",
            timeout=120,
        )

    with subtest("nixbot: nginx proxies to the service Unix socket"):
        github.wait_for_unit("nginx.service")
        github.wait_for_unit("nixbot.service")
        github.fail("curl --fail -s http://127.0.0.1:8010/health")
        github.wait_until_succeeds(
            f"curl --fail -s {nixbot_url}/health", timeout=120
        )

    with subtest("nixbot: project discovered from fake GitHub"):
        def github_project_discovered(_ignore):
            out = github.succeed(f"curl --fail -s {nixbot_url}/api/repos")
            projects = json.loads(out)
            print(projects)
            return any(
                p["owner"] == "acme" and p["name"] == "test-flake"
                for p in projects
            )

        retry(github_project_discovered, timeout_seconds=120)

    with subtest("nixbot: webhook triggers eval, build, and statuses"):
        sha = github.succeed("git -C /var/lib/test-repo rev-parse master").strip()
        body = json.dumps({
            "ref": "refs/heads/master",
            "after": sha,
            "repository": {"id": 1, "default_branch": "master"},
            "head_commit": {"message": "initial commit"},
        }).encode()
        webhook_secret = github.succeed(
            "cat /run/secrets/nixbot-github-webhook-secret"
        ).strip().encode()
        sig = hmac.new(webhook_secret, body, hashlib.sha256).hexdigest()
        github.succeed(
            f"curl --fail -s -X POST {nixbot_url}/webhooks/github "
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

    with subtest("cache: post-build upload is signed and readable from S3"):
        store_path = github.succeed(
            "nix eval --raw "
            "'git+file:///var/lib/test-repo?ref=master"
            "#checks.x86_64-linux.test.outPath'"
        ).strip()
        store_hash = store_path.rsplit("/", 1)[1].split("-", 1)[0]
        s3_env = (
            "export S3_ENDPOINT_URL=http://127.0.0.1:9000\n"
            "export AWS_ACCESS_KEY_ID="
            "$(cat /run/secrets/niks3-s3-access-key)\n"
            "export AWS_SECRET_ACCESS_KEY="
            "$(cat /run/secrets/niks3-s3-secret-key)"
        )
        narinfo = github.succeed(
            f"{s3_env}\n"
            f"s5cmd cat s3://${s3Bucket}/{store_hash}.narinfo "
            "| zstd --decompress"
        )
        assert f"StorePath: {store_path}" in narinfo
        assert "Sig: niks3-test-1:" in narinfo

        # Fetching into an empty store verifies the nar and its signature, not
        # only the presence of an S3 metadata object.
        binary_cache_url = (
            "s3://${s3Bucket}?endpoint=http://127.0.0.1:9000"
            "&region=us-east-1"
        )
        github.succeed(
            f"{s3_env}\n"
            "mkdir -p /tmp/cache-store\n"
            f"nix copy --from '{binary_cache_url}' "
            f"--to /tmp/cache-store {store_path}"
        )
        content = github.succeed(
            f"nix --store /tmp/cache-store store cat {store_path}"
        ).strip()
        assert content == "hello"
  '';
}
