# Nixbot CI Setup at ci.phlip9.com

# Overview

## References

nixbot CI on sauna.phlip9.com (Hetzner 6c/12t server):
- `phlip9/dotfiles` build master + PRs
- `phlip9/notes-private` build master + deploy to GitHub pages

Components:
- [Mic92/nixbot](https://github.com/Mic92/nixbot): NixOS module for nixbot CI with Nix
- [Mic92/niks3](https://github.com/Mic92/niks3): S3-backed binary cache with GC (Cloudflare R2)
- nginx: HTTPS reverse proxy

## Architecture

```
GitHub webhook
    |
    v
https://ci.phlip9.com/webhooks/github
    |
    v
nginx (ci.phlip9.com:443)
    |
    v
nixbot (/run/nixbot/web.sock)
    |
    v
persistent upload queue -> niks3 push --stdin
                                  |
                                  v
                          niks3 server ([::1]:5751)
                                  |
                                  v
                            Cloudflare R2
                                  |
                                  v
                       cache.phlip9.com (public reads)
```

## Files

- `flake.nix`: Minimal flake wrapper exposing `.#checks` for nixbot
- `nixos/mods/nixbot-ci.nix`: Main module wrapping nixbot + niks3
- `nixos/mods/default.nix`: Imports nixbot and niks3 NixOS modules
- `nixos/sauna/default.nix`: Enables `services.phlip9-nixbot-ci`
- `nixos/tests/nixbot.nix`: Hermetic nixbot + niks3 + S3 integration test
- `nixos/sauna/secrets.yaml`: sops-encrypted secrets
- `npins/sources.json`: Pins for nixbot and niks3

## Config

```nix
services.phlip9-nixbot-ci = {
  enable = true;
  domain = "ci.phlip9.com";

  github = {
    appId = 2746100;
    oauthClientId = "Iv23liE6dM8w5D4JF7Qz";
  };

  cache = {
    url = "https://cache.phlip9.com";
    s3.endpoint = "30faeb30dcb2a77a72fdc0948c99de62.r2.cloudflarestorage.com";
    s3.bucket = "phlip9-nix-cache";
  };
};
```

Host concurrency is set in `nixos/sauna/default.nix`. Client cache trust is
configured separately in `nixos/mods/nix-cache.nix`.

### Cache lifetime

Configured in `ops/zone/phlip9.com.nix`:

| Response | TTL |
|----------|-----|
| `/nar/*` object | 1 year |
| metadata (`nix-cache-info`, `*.narinfo`, `*.ls`) | 2 hours |
| 404 | 10 minutes |
| Other 4xx/5xx | Not cached |

### Secrets

All secrets in `nixos/sauna/secrets.yaml`:

- `niks3-api-token`
- `niks3-s3-access-key`: Cloudflare R2 API token
- `niks3-s3-secret-key`: Cloudflare R2 API token
- `niks3-signing-key`
- `nixbot-github-app-secret-key`: GitHub App private key (.pem file)
- `nixbot-github-oauth-client-secret`: GitHub App OAuth Client secret
- `nixbot-github-webhook-secret`

#### Generating Secrets

```bash
echo -e "\n=== GitHub webhook secret ==="
openssl rand -hex 32

echo -e "\n=== niks3 API token ==="
openssl rand -base64 48 | tr -- '+/' '-_' | tr -d '=\n'

echo -e "\n=== niks3 signing key ==="
nix key generate-secret --key-name cache.phlip9.com-1 | tee key && echo ""

echo -e "\n=== niks3 signing pubkey (for nix clients) ==="
nix key convert-secret-to-public < key && echo ""
```

## Setup

### GitHub App Setup

- Go to <https://github.com/settings/apps/new>

- **Basic info**:
   - Name: `phlip9-nixbot-ci`
   - Homepage: `https://ci.phlip9.com`

- **Identifying and authorizing users**
   - Callback URL: `https://ci.phlip9.com/auth/github/callback`
   - Enable Device Flow (Optional)

- **Webhook**:
   - URL: `https://ci.phlip9.com/webhooks/github`
   - Secret: generate with `openssl rand -hex 32`

- **Repository permissions**:
   - Commit statuses: Read and write
   - Checks: Read and write
   - Contents: Read-only
   - Metadata: Read-only (set by default)
   - Pull requests: Read-only

- **Organization permissions** (if app is for an org):
   - Members: Read-only

- **Events**: Push, Pull request, Check run, Check suite

- **After creation:**
   - Note the App ID and OAuth Client ID
   - Generate and download App private key (.pem)
   - Generate and copy OAuth Client secret

### Cloudflare R2 Setup

- Create bucket `phlip9-nix-cache`
- Connect custom domain `cache.phlip9.com`
- Create API token with Object Read & Write on the bucket
- Note Access Key ID and Secret Access Key

### Repository Setup

- Install `phlip9-nixbot-ci` GitHub App on `phlip9/dotfiles`
- Ensure `flake.nix` exists with `.#checks` output

## Concrete Values

**GitHub App** (`phlip9-nixbot-ci`):
- App ID: `2746100`
- OAuth Client ID: `Iv23liE6dM8w5D4JF7Qz`

**Cloudflare R2**:
- Bucket: `phlip9-nix-cache`
- Custom domain: `cache.phlip9.com`
- Account ID: `30faeb30dcb2a77a72fdc0948c99de62`
- S3 endpoint: `30faeb30dcb2a77a72fdc0948c99de62.r2.cloudflarestorage.com`

**Cache signing pubkey**:
- `cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4=`

## Validation

Run the integration test before deployment:

```bash
nix build -f . nixosTests.nixbot --no-link
```

After deployment, check nginx/webhook delivery, cache uploads to R2, and the
`niks3-gc` timer. On sauna, `curl -g 'http://[::1]:5751/health'` to check niks3
liveness and `/readyz` to check DB connection.

## Adding New Repos

- Install the `phlip9-nixbot-ci` GitHub App on the repo
- Ensure repo has `flake.nix` with `.#checks`
- Reload repos in the nixbot UI and enable the repo. With `github.topic = null`,
  discovery does not automatically enable new repos.
- Push to trigger first build
