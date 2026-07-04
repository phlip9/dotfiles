# Nixbot CI Setup for omnara1.phlip9.com

# Overview

## References

nixbot CI on omnara1 (Hetzner 6c/12t server) to build:
- `phlip9/dotfiles` master + PRs

Components:
- [Mic92/nixbot](https://github.com/Mic92/nixbot): NixOS module for nixbot CI with Nix
- [Mic92/niks3](https://github.com/Mic92/niks3): S3-backed binary cache with GC (Cloudflare R2)
- nginx: HTTPS reverse proxy

## Architecture

```
GitHub webhook
    │
    ▼
https://ci.phlip9.com/webhooks/github
    │
    ▼
nginx (ci.phlip9.com:443)
    │
    ├─► nixbot (127.0.0.1:8010) ───► niks3 push (post-build)
    │                                       │
    │                                       ▼
    └─► niks3 server ([::1]:5751) ─► Cloudflare R2
                                            │
                                            ▼
                                   cache.phlip9.com (public reads)
```

## Files

- `flake.nix`: Minimal flake wrapper exposing `.#checks` for nixbot
- `nixos/mods/nixbot-ci.nix`: Main module wrapping nixbot + niks3
- `nixos/mods/default.nix`: Imports nixbot and niks3 NixOS modules
- `nixos/omnara1/default.nix`: Enables `services.phlip9-nixbot-ci`
- `nixos/omnara1/secrets.yaml`: sops-encrypted secrets
- `npins/sources.json`: Pins for nixbot and niks3

## Config

```nix
services.phlip9-nixbot-ci = {
  enable = true;
  domain = "ci.phlip9.com";
  cacheDomain = "cache.phlip9.com";

  github = {
    appId = 2746100;
    oauthClientId = "Ov23lipvJOGiZTG0aqv9";
  };

  cloudflare = {
    accountId = "30faeb30dcb2a77a72fdc0948c99de62";
    bucket = "phlip9-nix-cache";
  };

  cache.publicKey = "cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4=";
};
```

### Secrets

All secrets in `nixos/omnara1/secrets.yaml`:

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

**Cache signing key** (public):
- `cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4=`

## Checklist

### Before deployment:
- [ ] Create Cloudflare R2 bucket
- [ ] Connect cache.phlip9.com domain
- [ ] Create R2 API token
- [ ] Create GitHub App
- [ ] Generate all secrets
- [ ] Encrypt secrets with sops
- [ ] Add nixbot-nix + niks3 to npins
- [ ] Install GitHub App on repo

### After deployment:
- [ ] Verify ACME cert for ci.phlip9.com
- [ ] Test webhook delivery
- [ ] Test cache uploads to R2
- [ ] Verify niks3-gc timer is active

## Adding New Repos

- Install the `phlip9-nixbot-ci` GitHub App on the repo
- Ensure repo has `flake.nix` with `.#checks`
- Push to trigger first build
