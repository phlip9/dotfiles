# Intermittent aarch64-darwin nix remote builder on phliptop-mbp

My agents on sauna (x86_64-linux) occasionally need to build aarch64-darwin nix
derivations. phliptop-mbp is my apple M1 MBP that's usually plugged in at work,
behind a NAT. This doc covers how I expose phliptop-mbp as a nix remote builder
to sauna.

I run one command, `darwin-builder-serve`, that starts a user-owned sshd at
`127.0.0.1:22024` and an outbound reverse tunnel to sauna `127.0.0.1:22023`.

sauna then has phliptop-mbp configured as a nix remote builder at
`127.0.0.1:22023`, so aarch64-darwin derivations are automatically built on
phliptop-mbp.

The `darwin-builder-serve` command bundles the sshd config, creates a
persistent host key, and cleans up on Ctrl+C. Inside, `autossh` reconnects the
tunnel after sauna restarts or network drops. `caffeinate -s` prevents sleep
while phliptop-mbp is plugged in.

See:

- <../pkgs/darwin-builder-serve.nix>
- <../nixos/mods/darwin-builder.nix>


## Requirements

- Outbound SSH only. No VPN.
- One foreground command, so it's easy to enable/disable. I only want to expose
  this occasionally.
- No macOS Remote Login, no root, no Full Disk Access.
- Only sauna can connect. Once connected, agents can only build nix drvs.
- Fail fast on sauna when phliptop-mbp is offline.
- phliptop-mbp should stay connected even when the laptop lid is closed and
  screen locked.

Agents and build inputs are trusted.


## Runbooks

### Start and stop

1. **phliptop-mbp:** run `darwin-builder-serve`
2. **sauna:** build derivations:

   ```bash
   $ nix build -f . --argstr localSystem aarch64-darwin pkgs.hello
   ```

3. **phliptop-mbp:** Ctrl+C to stop


### Setup

1. **sauna:** create the client key if absent

   ```bash
   $ sudo install -d -m 700 /root/.ssh
   $ if ! sudo test -f /root/.ssh/phliptop-mbp-builder; then \
       sudo ssh-keygen -q -t ed25519 -N '' \
         -f /root/.ssh/phliptop-mbp-builder \
     fi
   $ sudo chmod 600 /root/.ssh/phliptop-mbp-builder
   $ sudo ssh-keygen -y -f /root/.ssh/phliptop-mbp-builder
   ```

   - <../pkgs/darwin-builder-serve.nix>: update the pubkey in `authorizedKeys`

2. **phliptop-mbp:**

   ```bash
   $ nix config show | grep -E '^(max-jobs|system-features) ='
   max-jobs = 8
   system-features = apple-virt benchmark big-parallel nixos-test

   $ hms
   $ darwin-builder-serve
   Builder host public key (pin on sauna):
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAsnrrEChMI9jxAJWvqYF/x2/oNn9cecuS2tbpHMqHG9 phliptop-mbp-builder-host

   Starting builder via sauna. Ctrl+C stops serving.
   Server listening on 127.0.0.1 port 22024.
   autossh[95693]: port set to 0, monitoring disabled
   autossh[95693]: starting ssh (count 1)
   autossh[95693]: ssh child pid is 95695
   ```

   copy the pubkey. leave the command running.

   - <../nixos/mods/darwin-builder.nix>: set `hostPublicKey`, update
     `maxJobs`/`supportedFeatures` if necessary.
   - <../nixos/sauna/default.nix>: `phlip9.darwin-builder.enable = true;`

3. **sauna:**

   ```bash
   $ nors
   $ sudo nix store info --json --store ssh-ng://phlip9@phliptop-mbp-builder
   ```


### Verify a new setup

1. **Sauna repo:** create and build the smoke derivation. Require a remote
   build log and output `Darwin arm64` followed by `Hello, world!`.

   ```sh
   mkdir -p tmp
   cat > tmp/darwin-builder-smoke.nix <<'EOF'
   { nonce }:
   let
     pkgs = (import ../. { localSystem = "aarch64-darwin"; }).pkgs;
   in
   pkgs.runCommand "darwin-builder-smoke"
     { inherit nonce; nativeBuildInputs = [ pkgs.hello ]; }
     ''
       uname -sm > "$out"
       hello >> "$out"
     ''
   EOF

   nix build -f tmp/darwin-builder-smoke.nix \
     --argstr nonce "$(date +%s%N)" --max-jobs 0 -L \
     --out-link tmp/darwin-builder-smoke
   cat tmp/darwin-builder-smoke
   ```

2. **Mac:** connect AC, display, and input devices; lock and close the lid;
   put the display to sleep. After one minute, repeat the build; require
   success.

3. **Mac:** stop with Ctrl+C. Require connection refused from
   `/usr/bin/nc -vz -w 3 127.0.0.1 22024`. **Sauna:** repeat the build;
   require prompt failure and no listener in `ss -ltn 'sport = :22023'`.
