# End-to-end NixOS VM test for the Paseo daemon, relay, and nginx wiring.
{
  name = "paseo";

  globalTimeout = 300;

  nodes.machine =
    { config, pkgs, ... }:
    let
      # Stand-in for Home Manager's ~/.profile -> hm-session-vars.sh, w/ its
      # one-time guard and sessionPath prepend. Exercises derived session
      # exports without importing Home Manager or provisioning Postgres.
      hmProfile = pkgs.writeText "profile" ''
        if [ -n "''${__HM_SESS_VARS_SOURCED-}" ]; then return; fi
        export __HM_SESS_VARS_SOURCED=1
        export PATH="$HOME/.local/bin''${PATH:+:}$PATH"
        export PGHOST="$XDG_RUNTIME_DIR"
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/nix-ssh-agent.socket"
      '';

      # Fake ACP agent. Records the env seen by the agent process and by the
      # non-login (`bash -c`) and login (`bash -lc`) tool shells agents run.
      # Exits w/o speaking ACP; the test only needs the daemon to spawn it.
      agentEnvProbe = pkgs.writeShellScript "paseo-agent-env-probe" ''
        set -eu
        cd /tmp/paseo-agent-env
        # Write then rename, since the daemon may spawn concurrent probes.
        env > "agent-env.$$"
        bash -c env > "nonlogin-env.$$"
        bash -lc env > "login-env.$$"
        mv "agent-env.$$" agent-env
        mv "nonlogin-env.$$" nonlogin-env
        mv "login-env.$$" login-env
      '';
    in
    {
      environment.systemPackages = [
        config.services.paseo.package
        pkgs.curl
        pkgs.git
        pkgs.jq
      ];

      users.users.testuser = {
        isNormalUser = true;
        # Match headless startup and catch hardcoded UID 1000 runtime paths.
        uid = 1234;
        linger = true;
        shell = pkgs.bashInteractive;
      };

      systemd.tmpfiles.rules = [
        "L+ /home/testuser/.profile - - - - ${hmProfile}"
      ];

      # NixOS set-environment var, only loaded by login shells.
      environment.variables.TEST_SYSTEM_VAR = "1";

      services.paseo = {
        enable = true;
        user = "testuser";
        group = "users";
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
        # Simulate stale mutable config that conflicts with the declarative
        # service-proxy policy.
        settings.daemon.serviceProxy = {
          enabled = true;
          listen = "[::1]:6768";
          publicBaseUrl = "http://services.test";
        };
        settings.agents.providers.env-probe = {
          extends = "acp";
          label = "Env probe";
          command = [ "${agentEnvProbe}" ];
        };
        nginx = {
          forceSSL = false;
          enableACME = false;
        };
      };

      sops.secrets.paseo-daemon-password = { };
    };

  testScript = ''
    password_file = "/run/credentials/paseo.service/daemon-password"

    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Resolve the configured user's runtime paths without a prior login.
    user_uid = machine.succeed("id -u testuser").strip()
    runtime_dir = f"/run/user/{user_uid}"

    # Session env every daemon child should see: runtime dir, derived HM
    # session vars, NixOS set-environment vars, and HM sessionPath.
    expected_env = {
        "HOME": "/home/testuser",
        "XDG_RUNTIME_DIR": runtime_dir,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime_dir}/bus",
        "PGHOST": runtime_dir,
        "SSH_AUTH_SOCK": f"{runtime_dir}/nix-ssh-agent.socket",
        "TEST_SYSTEM_VAR": "1",
    }
    session_path_entry = "/home/testuser/.local/bin"
    env_key_pattern = "^(" + "|".join([*expected_env, "PATH"]) + ")="
    daemon_env_cmd = (
        "tr '\\0' '\\n' < "
        "/proc/$(systemctl show paseo.service -p MainPID --value)/environ"
    )

    def assert_session_env(env_dump_cmd: str) -> None:
        """Check selected keys in `env`-style output from env_dump_cmd."""
        env_lines = machine.succeed(
            f"{env_dump_cmd} | grep -E '{env_key_pattern}'"
        )
        env: dict[str, str] = {}
        for line in env_lines.splitlines():
            env_key, _, env_value = line.partition("=")
            env[env_key] = env_value
        for env_key, env_value in expected_env.items():
            assert env.get(env_key) == env_value, (
                f"{env_dump_cmd}: {env_key}={env.get(env_key)!r}"
            )
        # A child login shell that re-runs NixOS set-environment resets PATH,
        # then skips the already-sourced HM session vars.
        assert session_path_entry in env["PATH"].split(":"), (
            f"{env_dump_cmd}: PATH={env['PATH']}"
        )

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
        machine.succeed(
            "pid=$(systemctl show paseo.service -p MainPID --value); "
            "tr '\\0' '\\n' < /proc/$pid/environ "
            "| grep '^PASEO_RELAY_ENABLED=true$'"
        )
        machine.succeed(
            "pid=$(systemctl show paseo.service -p MainPID --value); "
            "tr '\\0' '\\n' < /proc/$pid/environ "
            "| grep '^PASEO_SERVICE_PROXY_ENABLED=false$'"
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
        machine.succeed(
            "test \"$(paseo --version)\" = "
            "\"$(curl -g -sf -H 'Authorization: Bearer correct-password' "
            "http://[::1]:6767/api/status | jq -r .version)\""
        )
        machine.fail("curl -g -sf --connect-timeout 1 http://[::1]:6768/")
        machine.succeed("ss -H -ltnp | grep -F 'Paseo Daemon'")
        machine.fail(
            "ss -H -ltnp | grep -F 'Paseo Daemon' | awk '{print $4}' "
            "| grep -Ev '^(127[.]0[.]0[.]1|\\[::1\\]):'"
        )

    with subtest("daemon inherits the user's runtime environment"):
        machine.succeed(f"systemctl is-active user@{user_uid}.service")
        machine.succeed(f"test -S {runtime_dir}/bus")
        assert_session_env(daemon_env_cmd)

    with subtest("agent and its tool shells inherit the session env"):
        machine.succeed("install -d -m 0777 /tmp/paseo-agent-env")
        # The probe exits w/o speaking ACP, so the run fails or hangs until
        # the daemon's ACP init timeout. Only the spawn matters.
        machine.execute(
            f"PASEO_PASSWORD_FILE={password_file} timeout 15 "
            "paseo run --host '[::1]:6767' --provider env-probe "
            "--cwd /tmp/paseo-agent-env --background env-probe"
        )
        machine.wait_until_succeeds(
            "test -s /tmp/paseo-agent-env/login-env", timeout=30
        )
        for env_dump in ["agent-env", "nonlogin-env", "login-env"]:
            assert_session_env(f"cat /tmp/paseo-agent-env/{env_dump}")

    with subtest("terminal CLI drives a workspace terminal"):
        machine.succeed("install -d -m 0777 /tmp/paseo-terminal-test")
        machine.succeed(
            f"PASEO_PASSWORD_FILE={password_file} "
            "paseo terminal create --host '[::1]:6767' "
            "--cwd /tmp/paseo-terminal-test --name vm-terminal --json "
            "| jq -e '.name == \"vm-terminal\" "
            "and .cwd == \"/tmp/paseo-terminal-test\"'"
        )
        machine.succeed(
            f"PASEO_PASSWORD_FILE={password_file} "
            "paseo terminal send-keys --host '[::1]:6767' vm-terminal "
            "'env > terminal-env; "
            "echo paseo-terminal-file-ok > terminal-result; "
            "echo paseo-terminal-output-ok' Enter"
        )
        machine.wait_until_succeeds(
            "grep -Fx paseo-terminal-file-ok "
            "/tmp/paseo-terminal-test/terminal-result",
            timeout=30,
        )
        # Check exports from the actual terminal, not the test runner's shell.
        assert_session_env("cat /tmp/paseo-terminal-test/terminal-env")
        machine.succeed(
            f"PASEO_PASSWORD_FILE={password_file} "
            "paseo terminal capture --host '[::1]:6767' "
            "--scrollback vm-terminal "
            "| grep -Fx paseo-terminal-output-ok"
        )
        machine.succeed(
            f"PASEO_PASSWORD_FILE={password_file} "
            "paseo terminal kill --host '[::1]:6767' "
            "--json vm-terminal | jq -e '.success == true'"
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

    with subtest("stop kills terminal children and restart restores env"):
        machine.succeed(
            f"PASEO_PASSWORD_FILE={password_file} "
            "paseo terminal create --host '[::1]:6767' "
            "--cwd /tmp/paseo-terminal-test --name lifecycle-terminal --json"
        )
        # A detached child must also be cleaned up, not just the PTY shell.
        machine.succeed(
            f"PASEO_PASSWORD_FILE={password_file} "
            "paseo terminal send-keys --host '[::1]:6767' lifecycle-terminal "
            "'nohup sleep 600 >/dev/null 2>&1 & echo $! > child-pid; "
            "echo $$ > shell-pid' Enter"
        )
        machine.wait_until_succeeds(
            "test -s /tmp/paseo-terminal-test/shell-pid",
            timeout=30,
        )
        terminal_pid = machine.succeed(
            "cat /tmp/paseo-terminal-test/shell-pid"
        ).strip()
        child_pid = machine.succeed(
            "cat /tmp/paseo-terminal-test/child-pid"
        ).strip()
        # Children stay in the unit's cgroup, so stopping it kills them.
        machine.succeed(f"grep -q '/paseo[.]service$' /proc/{child_pid}/cgroup")
        machine.succeed("systemctl stop paseo.service")
        machine.wait_until_succeeds(
            f"test ! -e /proc/{terminal_pid} && test ! -e /proc/{child_pid}",
            timeout=30,
        )
        machine.succeed(f"systemctl is-active user@{user_uid}.service")
        machine.succeed("systemctl start paseo.service")
        machine.wait_for_unit("paseo.service")
        machine.wait_until_succeeds("curl -g -sf http://[::1]:6767/api/health")
        assert_session_env(daemon_env_cmd)
  '';
}
