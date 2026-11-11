# Two-node regtest NixOS test for the rbitcoin full node service.
#
# node1 mines blocks over RPC. node2 dials node1 over P2P, catches up via IBD,
# then follows new tips. Also covers systemd readiness (`Type=notify`, the
# `rbitcoin-synced.target`), unix socket + TCP Bearer RPC, health probes,
# VictoriaMetrics scraping `/metrics` via o11y, and chain state persistence
# across restarts.
{
  name = "rbitcoin";

  globalTimeout = 600;

  defaults =
    { config, pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.rbitcoin = {
        enable = true;
        network = "regtest";
        # TCP RPC on 127.0.0.1:18443.
        rpc.enable = true;
        # Like sauna: a unix RPC socket the `rbitcoin` group can use, which
        # plain `rbitcoin-cli` talks to.
        rpc.socketPath = "/run/rbitcoin/rpc.sock";
        # /healthz, /readyz on 127.0.0.1:9332.
        health.enable = true;
      };

      # nspawn test nodes share cgroupfs. Separate the service cgroups so
      # stopping one node cannot race the other node's cgroup cleanup.
      systemd.services.rbitcoin.serviceConfig.Slice =
        "${config.networking.hostName}.slice";
    };

  containers.node1 = {
    # Dual-stack P2P listen on [::]:18444, like sauna.
    services.rbitcoin.p2p.address = "::";
    services.rbitcoin.p2p.openFirewall = true;

    # RPC socket access: alice is in the node's group, bob isn't.
    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "rbitcoin" ];
    };
    users.users.bob.isNormalUser = true;
  };

  containers.node2 =
    {
      containers,
      lib,
      pkgs,
      ...
    }:
    let
      node1Ip = containers.node1.networking.primaryIPAddress;
      node1Port = toString containers.node1.services.rbitcoin.p2p.port;
    in
    {
      imports = [ ./lib/victoriametrics.nix ];

      # Esplora REST on 127.0.0.1:3000, like sauna (there on another port).
      # Turns on the scripthash index, which node2 builds after its IBD.
      services.rbitcoin.esplora.enable = true;

      # Regtest has no seeds. Dial node1's IPv4 address, which its [::]
      # listener accepts as a v4-mapped peer.
      services.rbitcoin.p2p.connect = [ "${node1Ip}:${node1Port}" ];

      # Scrape node2's metrics into VictoriaMetrics, like on sauna.
      services.phlip9-o11y = {
        enable = true;
        retentionPeriod = "1d";
        grafana = {
          adminPasswordFile = pkgs.writeText "gf-admin-pwd" "test-password";
          secretKeyFile = pkgs.writeText "gf-secret-key" "test-secret-key";
          secretsManagerKeyFile = pkgs.writeText "gf-sm-key" "test-sm-key";
        };
      };
      # Only VictoriaMetrics is under test.
      services.grafana.enable = lib.mkForce false;
      # The VM check waits for a scrape after node2's last new tip.
      services.victoriametrics.prometheusConfig.global.scrape_interval = "1s";
    };

  testScript = ''
    import hashlib
    import shlex
    from datetime import timedelta

    datadir = "/var/lib/rbitcoin"
    rpc_socket = "/run/rbitcoin/rpc.sock"
    # nixos/mods/rbitcoin.nix wraps the cli to always use `rpc_socket`, so it
    # never silently falls back to TCP.
    cli = "rbitcoin-cli"
    rpc_url = "http://127.0.0.1:18443/"
    health_url = "http://127.0.0.1:9332"
    getblockcount_req = (
        "'{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"getblockcount\"}'"
    )
    # Crosses Core's 2000-header `headers` batch and rbitcoin's 1024-block
    # IBD download window, so node2's IBD takes multiple rounds of each.
    ibd_blocks = 2100
    synced_marker = "/run/rbitcoin-ready/synced"

    def rpc(node, args: str) -> str:
        """Call JSON-RPC over the node's unix socket."""
        return node.succeed(f"{cli} {args}").strip()

    def wait_for_synced(node) -> None:
        """Wait for `rbitcoin-synced.target`: /readyz ok, all listeners up."""
        # Not `wait_for_unit`: it fails fast on an inactive unit w/o a
        # pending job, and only the path unit starts the target.
        try:
            node.wait_until_succeeds(
                "systemctl is-active rbitcoin-synced.target",
                timeout=timedelta(seconds=60),
            )
        except Exception:
            node.log(
                node.execute(
                    "systemctl status rbitcoin.service rbitcoin-synced.path "
                    "rbitcoin-synced.target; "
                    "journalctl -u rbitcoin.service -n 50 --no-pager"
                )[1]
            )
            raise

    def wait_for_following(node) -> None:
        """Wait for the node to follow the tip, per its systemd status."""
        node.wait_until_succeeds(
            "test \"$(systemctl show -p StatusText --value rbitcoin.service)\" "
            "= following",
            timeout=timedelta(seconds=60),
        )

    def assert_not_synced(node) -> None:
        """The target and its marker are gone, e.g. after a stop."""
        node.fail("systemctl is-active rbitcoin-synced.target")
        node.fail(f"test -e {synced_marker}")

    def mine(blocks: int, script: str = "51") -> str:
        """Mine `blocks` blocks on node1, paying their coinbases to the
        hex `script`. Returns the new tip hash."""
        node1.succeed(f"{cli} generatetodescriptor {blocks} 'raw({script})'")
        return rpc(node1, "getbestblockhash")

    def scripthash(script: str) -> str:
        """Electrum/Esplora scripthash of a hex script."""
        return hashlib.sha256(bytes.fromhex(script)).digest()[::-1].hex()

    def wait_for_tip(node, tip: str) -> None:
        """Wait for the node's best block to reach `tip`."""
        # `waitforblock` wakes on each new tip, vs. the driver's 1s retries.
        # On timeout, it returns the current tip, not an error. Like
        # `bitcoin-cli`, `rbitcoin-cli` sends string params as-is, unquoted.
        node.succeed(
            f"{cli} waitforblock {tip} 120000 "
            f"| jq -e --arg tip {tip} '.hash == $tip'",
            timeout=timedelta(seconds=150),
        )

    # Boot node2 only after node1 has a chain. A node at genesis w/ only
    # genesis peers never leaves IBD catch-up.
    node1.start()

    with subtest("node1 starts at genesis"):
        # At genesis w/o peers, catch-up ends at once.
        wait_for_following(node1)
        assert rpc(node1, "getblockcount") == "0"

    with subtest("RPC socket admits the rbitcoin group only"):
        node1.succeed(
            f"test \"$(stat -c '%a %U %G' {rpc_socket})\" "
            "= '660 rbitcoin rbitcoin'"
        )
        node1.succeed(f"test \"$(runuser -u alice -- {cli} getblockcount)\" = 0")
        node1.fail(f"runuser -u bob -- {cli} getblockcount")

    with subtest("node reports readiness and phase to systemd"):
        unit_prop = "systemctl show -p {} --value rbitcoin.service"
        assert node1.succeed(unit_prop.format("Type")).strip() == "notify"
        status_text = node1.succeed(unit_prop.format("StatusText")).strip()
        assert status_text == "following", status_text

    with subtest("rbitcoin.service is sandboxed"):
        # Exposure from 0 (best) to 10, but `--threshold` takes tenths:
        # 11 = 1.1. Raise only w/ a reason; see the sandbox in
        # nixos/mods/rbitcoin.nix.
        status, out = node1.execute(
            "systemd-analyze security --threshold=11 --no-pager "
            "rbitcoin.service 2>&1"
        )
        assert status == 0, out
        # The seccomp filter allows io_uring; the node logs its IO backend.
        node1.succeed(
            "journalctl -u rbitcoin.service -o cat --no-pager "
            "| grep -E 'rbitcoin-node starting .* io=io_uring'"
        )
        # `~@resources` still lets the node raise its NOFILE soft limit.
        node1.succeed(
            "grep -E '^Max open files +16384 ' "
            "/proc/$(systemctl show -p MainPID --value rbitcoin.service)/limits"
        )

    with subtest("health probes answer before the node is ready"):
        node1.succeed(f"curl -sf {health_url}/healthz")
        # The regtest genesis block is years old, so the tip is stale.
        node1.fail(f"curl -sf {health_url}/readyz")
        # So node1 follows the tip, but `startupNotify` hasn't run.
        assert_not_synced(node1)

    with subtest("TCP RPC requires the Bearer token"):
        node1.wait_for_open_port(18443)
        token_file = f"{datadir}/rpc.token"
        node1.succeed(
            f"test \"$(stat -c '%a %U' {token_file})\" = '600 rbitcoin'"
        )
        http_code = (
            "curl -s -o /dev/null -w '%{http_code}' "
            f"--data-binary {getblockcount_req}"
        )
        assert node1.succeed(f"{http_code} {rpc_url}") == "401"
        assert (
            node1.succeed(
                f"{http_code} -H 'Authorization: Bearer wrong' {rpc_url}"
            )
            == "401"
        )
        node1.succeed(
            f"curl -sf --data-binary {getblockcount_req} "
            f"-H \"Authorization: Bearer $(cat {token_file})\" {rpc_url} "
            "| jq -e '.result == 0'"
        )
        node1.succeed(
            "test \"$(rbitcoin-cli --rpc-url 127.0.0.1:18443 "
            f"--rpc-token-file {token_file} getblockcount)\" = 0"
        )

    with subtest("node1 mines blocks and becomes synced"):
        tip = mine(ibd_blocks)
        assert rpc(node1, "getblockcount") == str(ibd_blocks)
        # The fresh tip passes /readyz, and wakes the follow loop, which
        # then runs `startupNotify`.
        wait_for_synced(node1)
        node1.succeed(f"curl -sf {health_url}/readyz")

    node2.start()

    with subtest("node2 catches up to node1 over P2P"):
        # Synced means /readyz passed at the tip: no further waits.
        wait_for_synced(node2)
        assert rpc(node2, "getbestblockhash") == tip
        assert rpc(node2, "getblockcount") == str(ibd_blocks)
        node2.succeed(f"curl -sf {health_url}/readyz")
        # node2 dialed node1, so node1 sees an inbound peer and vice versa.
        node2.succeed(
            f"{cli} getpeerinfo | jq -e 'any(.[]; .inbound == false)'"
        )
        node1.succeed(f"{cli} getpeerinfo | jq -e 'any(.[]; .inbound)'")

    with subtest("node2 follows new tips from node1"):
        tip = mine(5)
        wait_for_tip(node2, tip)
        assert rpc(node2, "getblockcount") == str(ibd_blocks + 5)

    with subtest("VictoriaMetrics scrapes node2's metrics"):
        # o11y turns on `/metrics`. node1 has no o11y, so it 404s there.
        node1.fail(f"curl -sf {health_url}/metrics")
        node2.succeed(
            f"curl -sf {health_url}/metrics "
            f"| grep -Fx 'rbitcoin_blocks {ibd_blocks + 5}'"
        )
        vm_url = "http://127.0.0.1:8428"
        node2.wait_for_unit("victoriametrics.service")
        try:
            node2.wait_until_succeeds(
                f"curl -sf {vm_url}/api/v1/targets "
                "| jq -e '.data.activeTargets[] "
                "| select(.labels.job == \"rbitcoin\") | .health == \"up\"'",
                timeout=timedelta(seconds=60),
            )
        except Exception:
            node2.log(node2.succeed(f"curl -s {vm_url}/api/v1/targets"))
            raise
        # Scraped samples become searchable on VM's next pending rows
        # flush, up to 2s later. `force_flush` runs it now.
        for query in (
            'up{job="rbitcoin"} == 1',
            'rbitcoin_build_info{job="rbitcoin",network="regtest"} == 1',
            f'rbitcoin_blocks{{job="rbitcoin"}} == {ibd_blocks + 5}',
            'rbitcoin_connections{job="rbitcoin",direction="out"} >= 1',
        ):
            node2.wait_until_succeeds(
                f"curl -sf {vm_url}/internal/force_flush && "
                f"curl -sfG {vm_url}/api/v1/query "
                f"--data-urlencode {shlex.quote('query=' + query)} "
                "| jq -e '.data.result | length > 0'",
                timeout=timedelta(seconds=60),
            )

    with subtest("node2 serves Esplora w/ the scripthash index"):
        esplora_url = "http://127.0.0.1:3000"
        # Synced implies Esplora is up, after the index caught up.
        assert node2.succeed(f"curl -sf {esplora_url}/blocks/tip/hash") == tip
        # IBD's bulk build: every coinbase so far pays to `raw(51)`. The
        # index trails new tips briefly (write-behind).
        node2.wait_until_succeeds(
            f"curl -sf {esplora_url}/scripthash/{scripthash('51')} "
            f"| jq -e '.chain_stats.tx_count == {ibd_blocks + 5}'",
            timeout=timedelta(seconds=30),
        )
        # Write-behind: a new tip pays to a fresh script.
        tip = mine(1, script="52")
        wait_for_tip(node2, tip)
        node2.wait_until_succeeds(
            f"curl -sf {esplora_url}/scripthash/{scripthash('52')} "
            "| jq -e '.chain_stats.funded_txo_count == 1'",
            timeout=timedelta(seconds=30),
        )

    with subtest("chain state persists across restarts"):
        # Restart each node while the other is down, so it can't re-sync
        # its chain from its peer.
        node2.succeed("systemctl stop rbitcoin.service")
        # node2 was synced above. Stopping the node takes the target down.
        assert_not_synced(node2)
        node1.succeed("systemctl restart rbitcoin.service")
        wait_for_synced(node1)
        assert rpc(node1, "getbestblockhash") == tip
        node1.succeed("systemctl stop rbitcoin.service")
        node2.succeed("systemctl start rbitcoin.service")
        # node2 can't reach node1, so catch-up gives up on its stored chain.
        wait_for_synced(node2)
        assert rpc(node2, "getbestblockhash") == tip

    with subtest("node2 redials node1 and follows new tips"):
        node1.succeed("systemctl start rbitcoin.service")
        wait_for_synced(node1)
        tip = mine(1)
        wait_for_tip(node2, tip)
        assert rpc(node2, "getblockcount") == str(ibd_blocks + 7)
  '';
}
