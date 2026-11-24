# Agent Center on sauna

see: nixos/mods/agent-center.nix
see: ~/dev/lexe-projects/agent-center/doc/SETUP.md

## First install

1. Deploy sauna: `just deploy sauna` (service is skipped until step 2).
2. On sauna, as phlip9: `agent-center-install`.
3. On sauna, in ~/dev/dotfiles: `hms` (links the skill into
   `~/.claude/skills`, `~/.codex/skills`).

## Update

1. `git -C ~/dev/lexe-projects pull`
2. `agent-center-install`

Build another checkout: `agent-center-install <path-to-lexe-projects>`.

## Connect

1. `ssh -L 4400:127.0.0.1:4400 sauna`
2. Open http://127.0.0.1:4400

## Check

1. `systemctl status agent-center`
2. `journalctl -u agent-center -f`
3. In a Paseo agent: `agent-center inbox` prints `You owe nothing.`

## Data

- `/var/lib/agent-center/` (sqlite db, `backups/`)
