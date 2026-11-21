# Observability Runbooks

## Setup

1. Enable `services.phlip9-o11y.server` + `services.phlip9-o11y.collector`

2. Re-deploy: (ex: `just deploy sauna`)

3. Open grafana (ex: <https://grafana.phlip9.com>)

4. For setup, login with username=admin and the admin password from sops
   secrets.yaml:

   ```bash
   $ sops --decrypt nixos/sauna/secrets.yaml | yq -r '.grafana-admin-password' | wl-copy
   ```

5. Create `phlip9` user

   * Grafana > Administration > Users and access > Users > New user

     Name: Philip Kannegaard Hayes
     Email: philiphayes9@gmail.com
     Username: phlip9
     Password: (redacted)

     > Create user

     Permissions > Grafana Admin > Change > Yes

6. Logout and Login as `phlip9`

7. Update settings:

   Administration > General > Default preferences
   * Interface theme: Gilded grove


## Add a collector host

For a NixOS host `<host>` that pushes metrics + profiles to sauna. Needs
sops-nix on `<host>` (see doc/SECRETS.md).

1. Generate the host's ingest password + its htpasswd line:

   ```bash
   $ (umask 077; openssl rand -base64 32 > /tmp/o11y-password)
   $ echo "<host>:$(openssl passwd -6 -stdin < /tmp/o11y-password)"
   <host>:$6$...
   ```

2. Add the password to the host's secrets as `o11y-ingest-password`:

   ```bash
   $ sops nixos/<host>/secrets.yaml
   ```

   ```yaml
   o11y-ingest-password: <contents of /tmp/o11y-password>
   ```

3. Add the htpasswd line to sauna's `o11y-ingest-htpasswd`, one line per
   host:

   ```bash
   $ sops nixos/sauna/secrets.yaml
   ```

   ```yaml
   o11y-ingest-htpasswd: |
     <host>:$6$...
   ```

4. Delete the plaintext password:

   ```bash
   $ rm /tmp/o11y-password
   ```

5. Enable the collector in `nixos/<host>/default.nix`:

   ```nix
   services.phlip9-o11y.collector = {
     enable = true;
     profiling.enable = true;
     remote = {
       url = "https://sauna.phlip9.com/o11y";
       passwordFile = config.sops.secrets.o11y-ingest-password.path;
     };
   };
   sops.secrets.o11y-ingest-password.restartUnits = [
     "vmagent.service"
     "alloy.service"
   ];
   ```

6. Deploy sauna, then `<host>`:

   ```bash
   $ just deploy sauna
   # on <host>
   $ nor switch
   ```

7. Check on `<host>`:

   ```bash
   $ systemctl status vmagent alloy
   $ curl -s http://127.0.0.1:8429/metrics \
       | grep -E '^vmagent_remotewrite_(requests_total|samples_dropped_total)'
   $ curl -s http://127.0.0.1:12345/metrics \
       | grep -E '^pyroscope_write_(sent|dropped)_profiles_total'
   ```

   Expect `requests_total` w/ `status_code="2XX"` growing, and the dropped
   counters at 0.

8. Check in Grafana: pick `<host>` in the `instance` variable of "Node
   Exporter Full" and "Profiling".

9. To also alert on `<host>` (always-on hosts only), add it to
   `services.phlip9-o11y.server.alerting.instances` on sauna.

## Git Sync setup

1. Create a fine-grained PAT:
   <https://github.com/settings/personal-access-tokens/new>
   - Resource owner: `phlip9`
   - Repository access: `phlip9/dotfiles`
   - Permissions:
     - Administration: Read
     - Contents: Read and write
     - Metadata: Read
     - Pull requests: Read and write
     - Webhooks: Read and write
   - Expiry: 1 year

2. Add the secrets:

   ```bash
   $ sops set nixos/sauna/secrets.yaml '["grafana-secrets-manager-key"]' \
       "\"$(head -c 32 /dev/urandom | base64 -w0)\""
   $ sops nixos/sauna/secrets.yaml   # grafana-git-sync-token: github_pat_...
   ```

3. Merge `nixos/sauna/grafana/` to `master` (Grafana syncs from there), then
   `just deploy sauna`.

4. Check:

   ```bash
   $ ssh sauna systemctl status grafana-git-sync-setup.service
   $ curl -s -u phlip9 https://grafana.phlip9.com/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories/dotfiles \
       | jq .status
   ```

   Expect `health.healthy: true` and `webhook.id` set. The hook is listed
   under GitHub > dotfiles > Settings > Webhooks. Grafana owns it; don't
   edit it there.

5. First time only: delete the pre-existing dashboards in the UI
   (Dashboards > select all > Delete). Git Sync can't adopt a uid that
   already exists. Then Administration > Provisioning > dotfiles > Pull.
   Deleted dashboards stay under Dashboards > Recently deleted.

6. Round trip: edit a panel, Save, branch `master`, commit message, Save.
   `git pull` shows the commit. Push a manifest edit; Grafana shows it
   within seconds.

## Alerting setup (Discord + healthchecks.io)

Setup secrets used by alerting.

1. Discord: create a server (or reuse one) with two text channels:
   `#alerts` and `#watchdog`.

2. Webhook for `#alerts`: channel settings > Integrations > Webhooks > New
   Webhook, name `alertmanager`, Copy Webhook URL
   (`https://discord.com/api/webhooks/<id>/<token>`)

3. Your user id: User Settings > Advanced > Developer Mode on, then
   right-click your name > Copy User ID (a number).

4. Notifications, on every device: `#alerts` > Notification Settings >
   Only @mentions. `#watchdog` > All Messages. Phone: Do Not Disturb
   23:00-09:00 (Discord has no schedule; this is the night gate for
   `#watchdog`).

5. healthchecks.io: sign up (free plan), project `sauna`.
   - Integrations > Add Integration > Discord > Add to Discord, pick the
     server and `#watchdog`.
   - Add Check `sauna-watchdog`: Period 5 min, Grace 5 min.
   - Add Check `sauna-host`: Period 5 min, Grace 5 min.
   - Both checks: Integrations > enable Discord. Copy each Ping URL
     (`https://hc-ping.com/<uuid>`).

6. Secrets: `sops nixos/sauna/secrets.yaml`

   ```yaml
   alertmanager-discord-webhook-url: https://discord.com/api/webhooks/<id>/<token>
   alertmanager-env: |
       DISCORD_USER_ID=<number>
   healthchecks-watchdog-ping-url: https://hc-ping.com/<uuid>
   healthchecks-host-ping-url: https://hc-ping.com/<uuid>
   ```

7. Deploy, then try exercising alerts
   - `systemctl stop prometheus-nginx-exporter` for ~5 min
   - `systemctl stop victoriametrics` for ~15 min
   - `systemctl stop alertmanager` for ~10 min
   - `systemctl stop healthchecks-host-ping.timer` for ~10 min


## Agent access (mcp-grafana)

1. Grafana > Administration > Users and access > Service accounts > Add
   service account: name `phlipdesk`, role `Editor`. Add service account
   token > Generate. Copy the `glsa_...` token (shown once).

2. On each machine that runs agents (e.g. phlipdesk, sauna):

   ```bash
   $ cd ~/.config
   $ mkdir -m 0700 grafana
   # paste + Ctrl-D
   $ (umask 077 && cat > ~/.config/grafana/mcp-sa-token)
   # strip trailing newline just in case
   $ perl -0777 -i -pe 's/\s+\z//' -- ~/.config/grafana/mcp-sa-token
   ```

3. In the dotfiles repo run e.g. `claude`, approve the project MCP server
   `grafana` once, then `claude mcp list` -> `grafana ... connected`. Ask for
   `user_info`. Expect service account `phlipdesk`, role Editor.
