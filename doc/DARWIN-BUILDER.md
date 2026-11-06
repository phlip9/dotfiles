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

For big darwin builds, agents can instead build directly in phliptop-mbp's
store and copy back only the final result. See "Heavy builds" below.

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


### Heavy builds

Auto-routed remote builds copy every output back to sauna over the tunnel and
require several RTTs per drv. For big closures (ex: Android NDK), build in
phliptop-mbp's store instead.

1. **sauna:** build in phliptop-mbp's store. note that `--out-link` doesn't
   work with a remote `--store`.

   ```bash
   $ nix build -f . --argstr localSystem aarch64-darwin pkgs.hello \
       --store ssh-ng://phliptop-mbp-builder --eval-store auto \
       --no-link --print-out-paths
   /nix/store/...-hello-2.12.3
   ```

2. **sauna:** copy the result back. phlip9 is a trusted user on sauna, so it
   can import the unsigned paths.

   ```bash
   $ nix copy --no-check-sigs --from ssh-ng://phliptop-mbp-builder \
       /nix/store/...-hello-2.12.3
   $ nix build --out-link result /nix/store/...-hello-2.12.3
   ```


### Setup

1. **sauna:** create the client keys if absent: root (nix-daemon build hook)
   and phlip9 (heavy builds)

   ```bash
   $ sudo install -d -m 700 /root/.ssh
   $ sudo test -f /root/.ssh/phliptop-mbp-builder \
       || sudo ssh-keygen -q -t ed25519 -N '' \
         -C sauna-to-phliptop-mbp-builder \
         -f /root/.ssh/phliptop-mbp-builder
   $ test -f ~/.ssh/phliptop-mbp-builder \
       || ssh-keygen -q -t ed25519 -N '' \
         -C sauna-phlip9-to-phliptop-mbp-builder \
         -f ~/.ssh/phliptop-mbp-builder
   $ sudo ssh-keygen -y -f /root/.ssh/phliptop-mbp-builder
   $ ssh-keygen -y -f ~/.ssh/phliptop-mbp-builder
   ```

   - <../pkgs/darwin-builder-serve.nix>: update both pubkeys in
     `authorizedKeys`

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
   $ sudo nix store info --json --store ssh-ng://phliptop-mbp-builder
   $ nix store info --json --store ssh-ng://phliptop-mbp-builder
   ```


### Verify a new setup

1. **sauna:** create and build a test derivation:

   ```bash
   $ mkdir -p tmp
   $ cat > tmp/darwin-builder-smoke.nix <<'EOF'
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

   $ nix build -f tmp/darwin-builder-smoke.nix \
       --argstr nonce "$(date +%s%N)" --max-jobs 0 -L \
       --out-link tmp/darwin-builder-smoke
   $ cat tmp/darwin-builder-smoke
   ```

2. **phliptop-mbp:** connect power and close the lid. after one minute, repeat
   the build.

3. **phliptop-mbp:** stop with Ctrl+C.
