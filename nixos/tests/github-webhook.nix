# End-to-end NixOS VM test for github-webhook service.
#
# Run with: nix-build -f . nixosTests.github-webhook
#
# This test creates a VM with:
# - The github-webhook service configured to watch multiple repos
# - Simulated GitHub webhook POST requests
# - Verification that commands execute on push events
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
}:

let
  # Import our custom packages.
  dotfilesPath = ../../.;
  sources = import (dotfilesPath + "/npins") { };
  phlipPkgs = import (dotfilesPath + "/pkgs") {
    inherit pkgs sources;
  };
in

pkgs.nixosTest {
  name = "github-webhook";

  nodes.machine =
    { config, lib, pkgs, ... }:
    {
      # Import only the github-webhook module (not full module stack to avoid SOPS).
      imports = [ ../mods/github-webhook.nix ];

      # Provide phlipPkgs to the module.
      _module.args.phlipPkgs = phlipPkgs;

      # Basic system config.
      users.users.testuser = {
        isNormalUser = true;
        home = "/home/testuser";
        createHome = true;
      };

      # Install packages.
      environment.systemPackages = [
        pkgs.gitMinimal
        pkgs.curl
      ];

      # Configure github-webhook service.
      services.github-webhook = {
        enable = true;
        user = "testuser";
        port = 8673;

        listeners.test = {
          secretName = "test-webhook-secret";

          repos.test-repo1 = {
            fullName = "test/repo1";
            branches = [ "main" ];
            command = [
              "${pkgs.bash}/bin/bash"
              "-c"
              "echo 'repo1 triggered' > /tmp/repo1-result"
            ];
            workingDir = "/tmp/repo1-work";
            runOnStartup = true;
            quietMs = 100;
          };

          repos.test-repo2 = {
            fullName = "test/repo2";
            branches = [
              "master"
              "develop"
            ];
            command = [
              "${pkgs.bash}/bin/bash"
              "-c"
              "echo 'repo2 triggered on $GH_BRANCH' > /tmp/repo2-result"
            ];
            workingDir = "/tmp/repo2-work";
            runOnStartup = false;
            quietMs = 100;
          };
        };
      };

      # Create working directories.
      systemd.tmpfiles.rules = [
        "d /tmp/repo1-work 0755 testuser users -"
        "d /tmp/repo2-work 0755 testuser users -"
      ];

      # Mock the SOPS secret by creating it directly.
      sops.secrets.test-webhook-secret = {
        sopsFile = lib.mkDefault null;
        path = "/run/credentials/github-webhook/test-webhook-secret";
      };

      # Create test secret file before service starts.
      systemd.services.github-webhook.preStart = lib.mkBefore ''
        mkdir -p /run/credentials/github-webhook
        echo -n "test-secret-12345" > /run/credentials/github-webhook/test-webhook-secret
        chmod 600 /run/credentials/github-webhook/test-webhook-secret
      '';
    };

  testScript = ''
    import json
    import hashlib
    import hmac
    import time

    def make_signature(secret, body):
        """Generate GitHub webhook HMAC signature."""
        mac = hmac.new(secret.encode(), body.encode(), hashlib.sha256)
        return f"sha256={mac.hexdigest()}"

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("github-webhook.service")
    machine.wait_for_open_port(8673)

    # Test 1: Health check endpoint.
    print("Test 1: Health check...")
    machine.succeed("curl -f http://localhost:8673/healthz")
    print("✓ Test 1 passed: Health check OK")

    # Test 2: Verify runOnStartup executed for repo1.
    print("Test 2: Check runOnStartup...")
    machine.wait_for_file("/tmp/repo1-result", timeout=10)
    result = machine.succeed("cat /tmp/repo1-result").strip()
    assert result == "repo1 triggered", f"Expected 'repo1 triggered', got '{result}'"
    print("✓ Test 2 passed: runOnStartup executed")

    # Test 3: Send push webhook for repo1 (main branch).
    print("Test 3: Send push webhook for repo1...")
    secret = "test-secret-12345"
    payload = json.dumps({
        "ref": "refs/heads/main",
        "after": "abc123def456",
        "repository": {"full_name": "test/repo1"},
        "sender": {"login": "testuser"}
    })
    sig = make_signature(secret, payload)

    machine.succeed("rm -f /tmp/repo1-result")  # Clear previous result
    response = machine.succeed(f"""
        curl -X POST http://localhost:8673/webhooks/github \
          -H 'Content-Type: application/json' \
          -H 'X-GitHub-Event: push' \
          -H 'X-Hub-Signature-256: {sig}' \
          -d '{payload}' \
          -w '%{{http_code}}' -o /dev/null -s
    """).strip()
    assert response == "202", f"Expected 202, got {response}"

    # Wait for debounced execution.
    time.sleep(1)

    machine.wait_for_file("/tmp/repo1-result", timeout=5)
    result = machine.succeed("cat /tmp/repo1-result").strip()
    assert result == "repo1 triggered", f"Expected 'repo1 triggered', got '{result}'"
    print("✓ Test 3 passed: Push webhook triggered repo1")

    # Test 4: Send push webhook for repo2 (master branch) with environment context.
    print("Test 4: Send push webhook for repo2 with env context...")
    payload2 = json.dumps({
        "ref": "refs/heads/master",
        "after": "def456abc789",
        "repository": {"full_name": "test/repo2"},
        "sender": {"login": "alice"}
    })
    sig2 = make_signature(secret, payload2)

    response = machine.succeed(f"""
        curl -X POST http://localhost:8673/webhooks/github \
          -H 'Content-Type: application/json' \
          -H 'X-GitHub-Event: push' \
          -H 'X-Hub-Signature-256: {sig2}' \
          -d '{payload2}' \
          -w '%{{http_code}}' -o /dev/null -s
    """).strip()
    assert response == "202", f"Expected 202, got {response}"

    time.sleep(1)
    machine.wait_for_file("/tmp/repo2-result", timeout=5)
    result = machine.succeed("cat /tmp/repo2-result").strip()
    assert result == "repo2 triggered on master", f"Expected branch context, got '{result}'"
    print("✓ Test 4 passed: Push webhook triggered repo2 with environment context")

    # Test 5: Reject webhook for wrong branch (repo2/feature).
    print("Test 5: Reject webhook for untracked branch...")
    payload3 = json.dumps({
        "ref": "refs/heads/feature",
        "after": "xyz789",
        "repository": {"full_name": "test/repo2"},
        "sender": {"login": "bob"}
    })
    sig3 = make_signature(secret, payload3)

    machine.succeed("rm -f /tmp/repo2-result")
    response = machine.succeed(f"""
        curl -X POST http://localhost:8673/webhooks/github \
          -H 'Content-Type: application/json' \
          -H 'X-GitHub-Event: push' \
          -H 'X-Hub-Signature-256: {sig3}' \
          -d '{payload3}' \
          -w '%{{http_code}}' -o /dev/null -s
    """).strip()
    assert response == "400", f"Expected 400, got {response}"

    time.sleep(1)
    # Should not create result file.
    machine.fail("test -f /tmp/repo2-result")
    print("✓ Test 5 passed: Rejected webhook for untracked branch")

    # Test 6: Reject webhook with invalid signature.
    print("Test 6: Reject webhook with invalid signature...")
    payload4 = json.dumps({
        "ref": "refs/heads/main",
        "repository": {"full_name": "test/repo1"},
        "sender": {"login": "eve"}
    })
    bad_sig = "sha256=badbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbadbaad"

    machine.succeed("rm -f /tmp/repo1-result")
    response = machine.succeed(f"""
        curl -X POST http://localhost:8673/webhooks/github \
          -H 'Content-Type: application/json' \
          -H 'X-GitHub-Event: push' \
          -H 'X-Hub-Signature-256: {bad_sig}' \
          -d '{payload4}' \
          -w '%{{http_code}}' -o /dev/null -s
    """).strip()
    assert response == "401", f"Expected 401, got {response}"

    time.sleep(1)
    machine.fail("test -f /tmp/repo1-result")
    print("✓ Test 6 passed: Rejected webhook with invalid signature")

    # Test 7: Accept ping event.
    print("Test 7: Accept ping event...")
    ping_payload = json.dumps({"zen": "Keep it simple."})
    ping_sig = make_signature(secret, ping_payload)

    response = machine.succeed(f"""
        curl -X POST http://localhost:8673/webhooks/github \
          -H 'Content-Type: application/json' \
          -H 'X-GitHub-Event: ping' \
          -H 'X-Hub-Signature-256: {ping_sig}' \
          -d '{ping_payload}' \
          -w '%{{http_code}}' -o /dev/null -s
    """).strip()

    assert response == "204", f"Expected 204 for ping, got '{response}'"
    print("✓ Test 7 passed: Ping event accepted")

    print("✅ All tests passed!")
  '';
}
