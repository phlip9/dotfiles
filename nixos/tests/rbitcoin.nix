# Two-node regtest NixOS test for the rbitcoin full node service.
#
# node1 mines blocks over RPC. node2 dials node1 over P2P, catches up via IBD,
# then follows new tips. Also covers unix socket + TCP Bearer RPC, health
# probes, and chain state persistence across restarts.
#
# Nodes are systemd-nspawn containers, not QEMU VMs, so they boot fast.
{
  name = "rbitcoin";

  globalTimeout = 600;

  defaults =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.rbitcoin = {
        enable = true;
        network = "regtest";
        # TCP RPC on 127.0.0.1:18443. Also binds the {dataDir}/rpc.sock socket.
        rpc.enable = true;
        # /healthz, /readyz on 127.0.0.1:9332.
        health.enable = true;
      };
    };

  containers.node1 = {
    services.rbitcoin.p2p.openFirewall = true;
  };

  containers.node2 =
    { containers, ... }:
    let
      node1Ip = containers.node1.networking.primaryIPAddress;
      node1Port = toString containers.node1.services.rbitcoin.p2p.port;
    in
    {
      # Regtest has no seeds. Dial node1 by IP, since node1 only listens on
      # IPv4 and its hostname may resolve to IPv6 first.
      services.rbitcoin.extraArgs = [
        "--connect"
        "${node1Ip}:${node1Port}"
      ];
    };

  testScript = ''
    from datetime import timedelta

    datadir = "/var/lib/rbitcoin"
    # Force the unix socket; w/o `--rpc-socket`, the cli silently falls back
    # to TCP when the socket is missing.
    cli = f"rbitcoin-cli --rpc-socket {datadir}/rpc.sock"
    rpc_url = "http://127.0.0.1:18443/"
    health_url = "http://127.0.0.1:9332"
    getblockcount_req = (
        "'{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"getblockcount\"}'"
    )
    # Crosses Core's 2000-header `headers` batch and rbitcoin's 1024-block
    # IBD download window, so node2's IBD takes multiple rounds of each.
    ibd_blocks = 2100

    def rpc(node, args: str) -> str:
        """Call JSON-RPC over the node's unix socket."""
        return node.succeed(f"{cli} {args}").strip()

    def wait_for_rpc(node) -> None:
        """Wait for the unix socket RPC to answer, e.g. after a restart."""
        node.wait_for_unit("rbitcoin.service")
        node.wait_until_succeeds(
            f"{cli} getblockcount", timeout=timedelta(seconds=60)
        )

    def mine(blocks: int) -> str:
        """Mine `blocks` blocks on node1. Returns the new tip hash."""
        node1.succeed(f"{cli} generatetodescriptor {blocks} 'raw(51)'")
        return rpc(node1, "getbestblockhash")

    def wait_for_tip(node, tip: str) -> None:
        """Wait for the node's best block to reach `tip`."""
        # `waitforblock` checks the tip every 50ms, vs. the driver's 1s
        # retries. On timeout, it returns the current tip, not an error.
        node.succeed(
            f"{cli} waitforblock '\"{tip}\"' 120000 "
            f"| jq -e --arg tip {tip} '.hash == $tip'",
            timeout=timedelta(seconds=150),
        )

    def wait_for_ready(node) -> None:
        """Wait for /readyz: following a fresh tip w/ all listeners up."""
        node.wait_until_succeeds(
            f"curl -sf {health_url}/readyz", timeout=timedelta(seconds=60)
        )

    # Boot node2 only after node1 has a chain. A node at genesis w/ only
    # genesis peers never leaves IBD catch-up.
    node1.start()

    with subtest("node1 starts at genesis"):
        wait_for_rpc(node1)
        assert rpc(node1, "getblockcount") == "0"
        node1.succeed(
            f"test \"$(stat -c '%a %U' {datadir}/rpc.sock)\" = '600 rbitcoin'"
        )

    with subtest("health probes answer before the node is ready"):
        node1.wait_until_succeeds(f"curl -sf {health_url}/healthz")
        # The regtest genesis block is years old, so the tip is stale.
        node1.fail(f"curl -sf {health_url}/readyz")

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

    with subtest("node1 mines blocks and becomes ready"):
        tip = mine(ibd_blocks)
        assert rpc(node1, "getblockcount") == str(ibd_blocks)
        wait_for_ready(node1)

    node2.start()

    with subtest("node2 catches up to node1 over P2P"):
        wait_for_rpc(node2)
        wait_for_tip(node2, tip)
        assert rpc(node2, "getblockcount") == str(ibd_blocks)
        wait_for_ready(node2)
        # node2 dialed node1, so node1 sees an inbound peer and vice versa.
        node2.succeed(
            f"{cli} getpeerinfo | jq -e 'any(.[]; .inbound == false)'"
        )
        node1.succeed(f"{cli} getpeerinfo | jq -e 'any(.[]; .inbound)'")

    with subtest("node2 follows new tips from node1"):
        tip = mine(5)
        wait_for_tip(node2, tip)
        assert rpc(node2, "getblockcount") == str(ibd_blocks + 5)

    with subtest("chain state persists across restarts"):
        # Restart each node while the other is down, so it can't re-sync
        # its chain from its peer.
        node2.succeed("systemctl stop rbitcoin.service")
        node1.succeed("systemctl restart rbitcoin.service")
        wait_for_rpc(node1)
        assert rpc(node1, "getbestblockhash") == tip
        node1.succeed("systemctl stop rbitcoin.service")
        node2.succeed("systemctl start rbitcoin.service")
        wait_for_rpc(node2)
        assert rpc(node2, "getbestblockhash") == tip

    with subtest("node2 redials node1 and follows new tips"):
        node1.succeed("systemctl start rbitcoin.service")
        wait_for_rpc(node1)
        tip = mine(1)
        wait_for_tip(node2, tip)
        assert rpc(node2, "getblockcount") == str(ibd_blocks + 6)
  '';
}
