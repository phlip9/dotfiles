# End-to-end NixOS container test for Paseo daemon, relay, CLI, and nginx.
#
#   paseo CLI / probe --WS/HTTP--> paseo.service (bash -lc, LoadCredential)
#                     --nginx----> paseo-relay.service (Noise NK E2EE)
#
# Verifies systemd/user-session wiring, enforced config merging, precompiled
# built-in plugins, disabled plugin installs/provider updates, env inheritance
# and secret scrubbing across agents + terminals, relay password auth, and
# cgroup cleanup on stop.
{
  name = "paseo";

  globalTimeout = 300;

  containers.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      paseoPkg = config.services.paseo.package;

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

      # Single Node.js probe that boots while paseo-server starts, overlaps
      # HTTP/CORS/CLI checks w/ built-in plugin load, and shares one WebSocket
      # session across RPC, plugin, agent, terminal, and relay auth checks.
      rpcProbe = pkgs.writeText "paseo-rpc-probe.mjs" ''
        import assert from "node:assert/strict";
        import { execFile } from "node:child_process";
        import { globSync, statSync } from "node:fs";
        import { promisify } from "node:util";
        import {
          DaemonAuthenticationError,
          DaemonClient,
        } from "${paseoPkg}/lib/paseo/packages/client/dist/daemon-client.js";
        import { createHostClient } from "${paseoPkg}/lib/paseo/packages/client/dist/node/index.js";
        import { builtinPlugins } from "${paseoPkg}/lib/paseo/packages/server/dist/server/server/plugins/builtin/index.js";

        const execFileAsync = promisify(execFile);
        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

        const PASSWORD = "correct-password";
        const PASSWORD_FILE = "/run/credentials/paseo.service/daemon-password";
        const PASEO_BIN = "${paseoPkg}/bin/paseo";
        const DAEMON_HTTP = "http://[::1]:6767";

        async function waitForFile(path, timeoutMs = 15_000) {
          const deadline = Date.now() + timeoutMs;
          while (Date.now() < deadline) {
            try {
              if (statSync(path).size > 0) return;
            } catch {}
            await sleep(10);
          }
          throw new Error(`Timed out waiting for non-empty file: ''${path}`);
        }

        async function waitForHealth(timeoutMs = 45_000) {
          const deadline = Date.now() + timeoutMs;
          let lastErr;
          while (Date.now() < deadline) {
            try {
              const resp = await fetch(`''${DAEMON_HTTP}/api/health`, {
                signal: AbortSignal.timeout(2_000),
              });
              if (resp.ok) return;
              lastErr = `HTTP ''${resp.status}`;
            } catch (err) {
              lastErr = err;
            }
            await sleep(25);
          }
          throw new Error(`Daemon health timed out: ''${String(lastErr)}`);
        }

        // Wait for wsServer to finish built-in plugin load (503 at start).
        async function connectDirect(timeoutMs = 25_000) {
          const deadline = Date.now() + timeoutMs;
          let lastErr;
          while (Date.now() < deadline) {
            const client = new DaemonClient({
              url: "ws://[::1]:6767/ws",
              clientId: "paseo-rpc-probe",
              password: PASSWORD,
              connectTimeoutMs: 5_000,
              reconnect: { enabled: false },
            });
            try {
              await client.connect();
              return client;
            } catch (err) {
              await client.close().catch(() => {});
              if (err instanceof DaemonAuthenticationError) throw err;
              lastErr = err;
              await sleep(25);
            }
          }
          throw new Error(`Direct connect timed out: ''${String(lastErr)}`);
        }

        // Probe the real `server` derivation: `$out/lib/paseo/node_modules` is
        // a symlink and Node 22 `globSync("**")` does not traverse symlinks.
        function assertNoRuntimeCompilers() {
          const root = "${paseoPkg.server}/lib/paseo";
          assert.deepEqual(
            globSync(
              "**/node_modules/{esbuild,@esbuild,typescript,@typescript/native-preview*}",
              { cwd: root },
            ),
            [],
          );
        }

        // Verify HTTP auth, CORS allowlist, and nginx web UI proxy while the
        // daemon finishes loading built-in plugins.
        async function assertHttpAndNginx() {
          const [unauth, authed, badCors, goodCors, webUi] = await Promise.all([
            fetch(`''${DAEMON_HTTP}/api/status`, {
              signal: AbortSignal.timeout(10_000),
            }),
            fetch(`''${DAEMON_HTTP}/api/status`, {
              headers: { Authorization: `Bearer ''${PASSWORD}` },
              signal: AbortSignal.timeout(10_000),
            }),
            fetch(`''${DAEMON_HTTP}/api/health`, {
              headers: { Origin: "https://app.paseo.sh" },
              signal: AbortSignal.timeout(10_000),
            }),
            fetch(`''${DAEMON_HTTP}/api/health`, {
              headers: { Origin: "http://paseo.test" },
              signal: AbortSignal.timeout(10_000),
            }),
            // Proves both bundled web UI serving and nginx reverse proxying.
            fetch("http://paseo.test/", {
              signal: AbortSignal.timeout(10_000),
            }),
          ]);

          assert.equal(unauth.status, 401);
          assert.equal(authed.status, 200);
          const statusBody = await authed.json();
          assert.equal(statusBody.status, "server_info");

          // Only the env-provided web UI origin may make CORS requests.
          assert.equal(badCors.status, 200);
          assert.equal(
            badCors.headers.get("access-control-allow-origin"),
            null,
          );
          assert.equal(goodCors.status, 200);
          assert.equal(
            goodCors.headers.get("access-control-allow-origin"),
            "http://paseo.test",
          );

          assert.equal(webUi.status, 200);
          const html = await webUi.text();
          assert.match(html, /<html/i);
        }

        // Exercise the packaged CLI wrapper, CLI PASEO_PASSWORD_FILE patch, and
        // valid-password Noise NK relay auth in a single CLI invocation.
        async function assertCliRelayAuth(pairingUrl) {
          const env = { ...process.env, PASEO_PASSWORD_FILE: PASSWORD_FILE };
          delete env.PASEO_PASSWORD;
          const { stdout } = await execFileAsync(
            PASEO_BIN,
            ["ls", "--host", pairingUrl, "--json"],
            { env, timeout: 15_000 },
          );
          JSON.parse(stdout);
        }

        // Verify relay client auth rejects missing/wrong passwords. Retries
        // transient connect failures while relay-control finishes attaching.
        async function assertRelayAuthRejected(
          pairingUrl,
          password,
          expectedReason,
          timeoutMs = 15_000,
        ) {
          const deadline = Date.now() + timeoutMs;
          let lastErr;
          while (Date.now() < deadline) {
            const relayClient = createHostClient(pairingUrl, {
              clientId: `relay-reject-''${expectedReason}`,
              ...(password !== undefined ? { password } : {}),
              connectTimeoutMs: 5_000,
              reconnect: { enabled: false },
            });
            try {
              await relayClient.connect();
            } catch (err) {
              await relayClient.close().catch(() => {});
              if (err instanceof DaemonAuthenticationError) {
                assert.equal(err.reason, expectedReason);
                return;
              }
              lastErr = err;
              await sleep(25);
              continue;
            }
            await relayClient.close().catch(() => {});
            throw new Error(
              `Relay client admitted (expected ''${expectedReason})`,
            );
          }
          throw new Error(
            `Relay auth reject timeout (''${expectedReason}): ''${String(lastErr)}`,
          );
        }

        async function assertBuiltinsLoaded(client) {
          const catalog = await client.getPluginCatalog();
          assert.deepEqual(
            catalog.map(({ id }) => id).sort(),
            [...builtinPlugins].sort(),
          );
        }

        async function assertPluginInstallsDisabled(client) {
          await Promise.all([
            assert.rejects(
              () => client.installPluginSource({ source: "npm:left-pad" }),
              /Managed plugin installs are disabled/,
            ),
            assert.rejects(
              () => client.listPluginRegistry(),
              /Managed plugin installs are disabled/,
            ),
            assert.rejects(
              () => client.getRegistryPlugin("acme/example"),
              /Managed plugin installs are disabled/,
            ),
          ]);
        }

        async function assertProviderUpdatesDisabled(client) {
          const [inspect, check, update] = await Promise.all([
            client.inspectProviderInstallation("claude"),
            client.checkProviderUpdates("claude"),
            client.updateProvider("claude"),
          ]);
          assert.equal(inspect.error, null);
          assert.equal(inspect.installation?.canUpdate, undefined);
          assert.equal(check.error, null);
          assert.equal(check.updateCheck, null);
          assert.equal(update.update, null);
          assert.match(update.error ?? "", /Provider updates are disabled/);
        }

        async function spawnAgentEnvProbe(client) {
          const project = await client.openProject("/tmp/paseo-agent-env");
          assert.ok(
            !project.error && project.workspace,
            `openProject failed: ''${project.error}`,
          );
          await assert.rejects(
            () =>
              client.createAgent({
                provider: "env-probe",
                cwd: "/tmp/paseo-agent-env",
                workspaceId: project.workspace.id,
                initialPrompt: "env-probe",
              }),
            /exited before initialization/i,
          );
          await waitForFile("/tmp/paseo-agent-env/login-env");
        }

        // Single workspace terminal covering PTY I/O, capture, env inheritance,
        // and a detached child left alive for the daemon stop cgroup check.
        async function runTerminalProbe(client) {
          const cwd = "/tmp/paseo-terminal-test";
          const project = await client.openProject(cwd);
          assert.ok(
            !project.error && project.workspace,
            `openProject failed: ''${project.error}`,
          );
          const created = await client.createTerminal(
            cwd,
            "vm-terminal",
            undefined,
            { workspaceId: project.workspace.id },
          );
          assert.ok(
            !created.error && created.terminal,
            `createTerminal failed: ''${created.error}`,
          );
          assert.equal(created.terminal.name, "vm-terminal");
          assert.equal(created.terminal.cwd, cwd);

          const cmd =
            "env > terminal-env.tmp && mv terminal-env.tmp terminal-env && " +
            "(nohup sleep 600 >/dev/null 2>&1 & echo $! > child-pid) && " +
            "echo $$ > shell-pid && " +
            "echo paseo-terminal-output-ok && " +
            "echo ok > terminal-ready\r";
          client.sendTerminalInput(created.terminal.id, {
            type: "input",
            data: cmd,
          });
          await waitForFile(`''${cwd}/terminal-ready`);

          const deadline = Date.now() + 10_000;
          let lastLines = [];
          while (Date.now() < deadline) {
            const captured = await client.captureTerminal(created.terminal.id, {
              start: 0,
              stripAnsi: true,
            });
            lastLines = captured.lines;
            if (lastLines.includes("paseo-terminal-output-ok")) return;
            await sleep(20);
          }
          throw new Error(
            `Terminal capture missing marker: ''${JSON.stringify(lastLines)}`,
          );
        }

        async function runWsChecks() {
          const client = await connectDirect();
          try {
            const pairing = await client.getDaemonPairingOffer();
            assert.equal(pairing.relayEnabled, true);
            assert.ok(
              typeof pairing.url === "string" &&
                pairing.url.startsWith("http://paseo.test/#offer="),
              `unexpected pairing url: ''${pairing.url}`,
            );
            // Offers pin clients to replay-protected (Noise NK) relay sessions.
            const rawOffer = pairing.url.split("#offer=", 2)[1];
            const offer = JSON.parse(
              Buffer.from(rawOffer, "base64url").toString("utf8"),
            );
            assert.equal(offer.minimumSecurityMode, "protected");

            // Gate the single-shot CLI call on `password_required` so
            // relay-control is guaranteed attached before the CLI connects.
            const relayReadyAndCli = assertRelayAuthRejected(
              pairing.url,
              undefined,
              "password_required",
            ).then(() => assertCliRelayAuth(pairing.url));

            await Promise.all([
              assertBuiltinsLoaded(client),
              assertPluginInstallsDisabled(client),
              assertProviderUpdatesDisabled(client),
              spawnAgentEnvProbe(client),
              runTerminalProbe(client),
              assertRelayAuthRejected(
                pairing.url,
                "wrong-password",
                "incorrect_password",
              ),
              relayReadyAndCli,
            ]);
          } finally {
            await client.close();
          }
        }

        assertNoRuntimeCompilers();
        await waitForHealth();

        // Overlap HTTP/CORS/nginx checks w/ built-in plugin load + WS checks.
        await Promise.all([assertHttpAndNginx(), runWsChecks()]);
      '';

      # Pre-existing, UI-managed config.json, like sauna's. Includes stale
      # values that conflict w/ declarative policy: an enabled service proxy,
      # upstream's default app.paseo.sh CORS origin, and enabled plugins.
      seedConfig = pkgs.writeText "paseo-seed-config.json" (
        builtins.toJSON {
          version = 1;
          daemon = {
            cors.allowedOrigins = [ "https://app.paseo.sh" ];
            serviceProxy = {
              enabled = true;
              listen = "[::1]:6768";
              publicBaseUrl = "http://services.test";
            };
          };
          pluginsEnabled = true;
          agents.providers = {
            muse.enabled = true;
            env-probe = {
              extends = "acp";
              label = "Env probe";
              command = [ "${agentEnvProbe}" ];
            };
          };
        }
      );
    in
    {
      environment.systemPackages = [
        paseoPkg
        pkgs.curl
        pkgs.git
        (pkgs.writeShellScriptBin "paseo-rpc-probe" ''
          exec ${lib.getExe pkgs.nodejs_22} ${rpcProbe}
        '')
      ];

      users.users.testuser = {
        isNormalUser = true;
        # Match headless startup and catch hardcoded UID 1000 runtime paths.
        uid = 1234;
        linger = true;
        shell = pkgs.bashInteractive;
      };

      # pam_unix checks shadowed accounts via the setuid unix_chkpwd wrapper,
      # which can't exist in the Nix build sandbox. Skip the account check so
      # testuser's lingering user@.service can start in the container.
      security.pam.services.systemd-user.rules.account.unix.modulePath =
        lib.mkForce "${lib.getLib pkgs.linux-pam}/lib/security/pam_permit.so";

      systemd.tmpfiles.rules = [
        "L+ /home/testuser/.profile - - - - ${hmProfile}"
        "C /home/testuser/.paseo/config.json 0600 testuser users - ${seedConfig}"
      ];

      # Resolve nginx vhosts locally, so pairing offers reach the relay.
      networking.hosts."127.0.0.1" = [
        "paseo.test"
        "relay.test"
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
        # Match the trailing newline in production sops secret files.
        auth.passwordFile = "${pkgs.writeText "paseo-daemon-password" "correct-password\n"}";
        hostnames = [
          "paseo.test"
        ];
        nginx = {
          forceSSL = false;
          enableACME = false;
        };
      };

      services.openssh.enable = lib.mkForce false;
    };

  testScript = ''
    import json
    import shlex

    from testlib import (
        CMD_TIMEOUT,
        CURL,
        UP_TIMEOUT,
        dump_evidence,
        wait_for_cmd,
        wait_for_http,
        wait_for_port,
        wait_for_value,
    )

    PASSWORD_FILE = "/run/credentials/paseo.service/daemon-password"
    CONFIG_FILE = "/home/testuser/.paseo/config.json"
    SESSION_PATH_ENTRY = "/home/testuser/.local/bin"

    EVIDENCE = [(
        machine,
        [
            "journalctl --no-pager -o cat -u paseo.service | tail -n 80",
            "journalctl --no-pager -o cat -u paseo-relay.service | tail -n 30",
            "journalctl --no-pager -o cat -u nginx.service | tail -n 30",
            "ss -Hltunp",
            f"cat {CONFIG_FILE}",
        ],
    )]

    # Parse `KEY=VAL` lines into a dict, tolerating values containing `=`.
    def parse_env(text: str) -> dict[str, str]:
        env: dict[str, str] = {}
        for line in text.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                env[key] = value
        return env

    # Verify required session vars and HM sessionPath are present.
    def assert_session_env(
        env: dict[str, str],
        expected: dict[str, str],
        label: str,
    ) -> None:
        for key, value in expected.items():
            assert env.get(key) == value, f"{label}: {key}={env.get(key)!r}"
        # A child login shell that re-runs NixOS set-environment resets PATH,
        # then skips the already-sourced HM session vars.
        path_val = env.get("PATH", "")
        assert SESSION_PATH_ENTRY in path_val.split(":"), (
            f"{label}: PATH={path_val}"
        )

    # Daemon children must not inherit the daemon password env.
    def assert_no_secret_env(env: dict[str, str], label: str) -> None:
        leaked = [
            key
            for key in ("PASEO_PASSWORD", "PASEO_PASSWORD_FILE")
            if key in env
        ]
        assert not leaked, f"{label}: leaked secret env {leaked}"

    machine.start()
    try:
        # --- Pre-listen checks (overlap w/ paseo-server cold start) --- #

        with subtest("relay and nginx proxy health"):
            machine.wait_for_unit("paseo-relay.service", timeout=UP_TIMEOUT)
            relay_health = json.loads(
                wait_for_http(machine, "http://[::1]:8411/health")
            )
            assert relay_health["status"] == "ok", relay_health

            machine.wait_for_unit("nginx.service", timeout=UP_TIMEOUT)
            wait_for_port(machine, 80)
            proxied_relay = json.loads(
                machine.succeed(
                    f"{CURL} -f -H 'Host: relay.test' http://127.0.0.1/health",
                    timeout=CMD_TIMEOUT,
                )
            )
            assert proxied_relay["status"] == "ok", proxied_relay

        with subtest("enforced settings and daemon runtime env"):
            machine.wait_for_unit("paseo.service", timeout=UP_TIMEOUT)
            user_uid = machine.succeed(
                "id -u testuser", timeout=CMD_TIMEOUT
            ).strip()
            runtime_dir = f"/run/user/{user_uid}"
            expected_env = {
                "HOME": "/home/testuser",
                "XDG_RUNTIME_DIR": runtime_dir,
                "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime_dir}/bus",
                "PGHOST": runtime_dir,
                "SSH_AUTH_SOCK": f"{runtime_dir}/nix-ssh-agent.socket",
                "TEST_SYSTEM_VAR": "1",
            }

            machine.succeed(
                f"systemctl show paseo.service -p ExecStart --value "
                f"| grep -E 'bash.*-lc' && "
                f"test -f {PASSWORD_FILE} && "
                f"systemctl is-active user@{user_uid}.service && "
                f"test -S {runtime_dir}/bus && "
                f"test \"$(stat -c %a:%U {CONFIG_FILE})\" = 600:testuser",
                timeout=CMD_TIMEOUT,
            )
            cfg = json.loads(
                machine.succeed(f"cat {CONFIG_FILE}", timeout=CMD_TIMEOUT)
            )
            assert cfg["daemon"]["cors"]["allowedOrigins"] == [], cfg
            assert cfg["pluginsEnabled"] is False, cfg
            assert cfg["agents"]["providers"]["muse"]["enabled"] is False, cfg
            assert (
                cfg["daemon"]["relay"]["requireProtectedSecurity"] is True
            ), cfg
            assert (
                cfg["agents"]["providers"]["env-probe"]["label"] == "Env probe"
            ), cfg
            assert cfg["daemon"]["serviceProxy"]["enabled"] is True, cfg

            # Wait until `bash -lc` sources profile and execs paseo-server.
            def read_daemon_env() -> dict[str, str] | None:
                rc, out = machine.execute(
                    "pid=$(systemctl show paseo.service -p MainPID --value) && "
                    "[ \"$pid\" -gt 0 ] && tr '\\0' '\\n' < /proc/$pid/environ",
                    timeout=CMD_TIMEOUT,
                )
                if rc != 0:
                    return None
                env = parse_env(out)
                return env if "TEST_SYSTEM_VAR" in env else None

            daemon_env = wait_for_value(
                read_daemon_env, "paseo.service login env"
            )
            assert (
                daemon_env.get("PASEO_PASSWORD_FILE") == PASSWORD_FILE
            ), daemon_env
            assert daemon_env.get("PASEO_RELAY_ENABLED") == "true", daemon_env
            assert (
                daemon_env.get("PASEO_SERVICE_PROXY_ENABLED") == "false"
            ), daemon_env
            assert "PASEO_PASSWORD" not in daemon_env, daemon_env
            assert_session_env(daemon_env, expected_env, "paseo.service")

            machine.succeed(
                "install -d -m 0777 "
                "/tmp/paseo-agent-env /tmp/paseo-terminal-test",
                timeout=CMD_TIMEOUT,
            )

        # --- HTTP/CORS/nginx, RPCs, plugins, agent/terminal, relay auth --- #

        with subtest("daemon HTTP, RPCs, plugins, terminal, and relay auth"):
            # Launch immediately so Node module import overlaps w/ paseo-server
            # cold start; the probe waits for /api/health and WS readiness.
            machine.succeed("paseo-rpc-probe", timeout=UP_TIMEOUT)

            ss_out = machine.succeed("ss -Hltnp", timeout=CMD_TIMEOUT)
            all_ports = {
                int(line.split()[3].rpartition(":")[2])
                for line in ss_out.splitlines()
            }
            # Service proxy stays disabled across all addresses (v4 and v6).
            assert 6768 not in all_ports, (all_ports, ss_out)
            daemon_addrs = [
                line.split()[3]
                for line in ss_out.splitlines()
                if "Paseo Daemon" in line
            ]
            assert "[::1]:6767" in daemon_addrs, (daemon_addrs, ss_out)
            for addr in daemon_addrs:
                host, _, _ = addr.rpartition(":")
                assert host in {"127.0.0.1", "[::1]"}, (daemon_addrs, ss_out)

        # --- Child env inheritance and secret scrubbing --- #

        with subtest("agent and terminal inherit session env without secrets"):
            env_files = [
                "/tmp/paseo-agent-env/agent-env",
                "/tmp/paseo-agent-env/nonlogin-env",
                "/tmp/paseo-agent-env/login-env",
                "/tmp/paseo-terminal-test/terminal-env",
            ]
            for env_file in env_files:
                raw_env = machine.succeed(
                    f"cat {shlex.quote(env_file)}",
                    timeout=CMD_TIMEOUT,
                )
                parsed_env = parse_env(raw_env)
                assert_session_env(parsed_env, expected_env, env_file)
                assert_no_secret_env(parsed_env, env_file)

        # --- Stop cleanup and restart config merge --- #

        with subtest("stop kills terminal children and restart merges config"):
            pids = machine.succeed(
                "cat /tmp/paseo-terminal-test/shell-pid "
                "/tmp/paseo-terminal-test/child-pid",
                timeout=CMD_TIMEOUT,
            ).splitlines()
            terminal_pid, child_pid = pids[0].strip(), pids[1].strip()
            # Prove both the PTY shell and detached sleep are live in the unit
            # cgroup before stopping it.
            machine.succeed(
                f"grep -q '/paseo[.]service$' /proc/{terminal_pid}/cgroup "
                f"&& grep -q '/paseo[.]service$' /proc/{child_pid}/cgroup",
                timeout=CMD_TIMEOUT,
            )
            wait_for_cmd(
                machine,
                f"test \"$(cat /proc/{child_pid}/comm)\" = sleep",
            )
            machine.succeed("systemctl stop paseo.service", timeout=CMD_TIMEOUT)
            wait_for_cmd(
                machine,
                f"test ! -e /proc/{terminal_pid} "
                f"&& test ! -e /proc/{child_pid}",
            )
            machine.succeed(
                f"systemctl is-active user@{user_uid}.service",
                timeout=CMD_TIMEOUT,
            )

            # Simulate a UI edit while stopped; ExecStartPre re-enforces policy
            # before `systemctl start` returns, so no second health wait needed.
            edited_cfg = json.loads(
                machine.succeed(f"cat {CONFIG_FILE}", timeout=CMD_TIMEOUT)
            )
            edited_cfg["daemon"]["autoArchiveAfterMerge"] = True
            edited_cfg["pluginsEnabled"] = True
            edit_cmd = (
                f"umask 077 && printf '%s\\n' "
                f"{shlex.quote(json.dumps(edited_cfg))} "
                f"> {CONFIG_FILE}.edit && mv {CONFIG_FILE}.edit {CONFIG_FILE}"
            )
            machine.succeed(
                f"runuser testuser -c {shlex.quote(edit_cmd)}",
                timeout=CMD_TIMEOUT,
            )
            machine.succeed("systemctl start paseo.service", timeout=CMD_TIMEOUT)
            restarted_cfg = json.loads(
                machine.succeed(f"cat {CONFIG_FILE}", timeout=CMD_TIMEOUT)
            )
            assert (
                restarted_cfg["daemon"]["autoArchiveAfterMerge"] is True
            ), restarted_cfg
            assert restarted_cfg["pluginsEnabled"] is False, restarted_cfg
    except Exception:
        dump_evidence(EVIDENCE)
        raise
  '';
}
