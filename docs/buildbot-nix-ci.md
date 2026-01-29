# Buildbot CI Setup for omnara1.phlip9.com

## Overview

Buildbot-nix CI on omnara1 (Hetzner 6c/12t server) to build:
- `phlip9/dotfiles` master + PRs (initial)
- Extensible to more repos later

Components:
- **buildbot-nix**: NixOS module for buildbot CI with Nix
- **niks3**: S3-backed binary cache with GC (Cloudflare R2)
- **oauth2-proxy**: Protect web UI (via buildbot-nix's `fullyPrivate` mode)

## Architecture

```
GitHub webhook
    │
    ▼
https://ci.phlip9.com/webhooks/github-buildbot-ci
    │
    ▼
nginx (ci.phlip9.com:443)
    │
    ├─► oauth2-proxy ([::1]:4180) ─► buildbot-master (127.0.0.1:8010)
    │   (skip-auth for /change_hook)        │
    │                                       ▼
    │                                buildbot-worker (10 workers)
    │                                       │
    │                                       ▼ (post-build)
    │                                  niks3 push
    │                                       │
    │                                       ▼
    └─► niks3 server ([::1]:5751) ─► Cloudflare R2
                                            │
                                            ▼
                                   cache.phlip9.com (public reads)
```

## Implementation Files

| File | Purpose |
|------|---------|
| `flake.nix` | Minimal flake wrapper exposing `.#checks` for buildbot-nix |
| `nixos/mods/buildbot-ci.nix` | Main module wrapping buildbot-nix + niks3 |
| `nixos/mods/default.nix` | Imports buildbot-nix and niks3 NixOS modules |
| `nixos/omnara1/default.nix` | Enables `services.phlip9-buildbot-ci` |
| `nixos/omnara1/secrets.yaml` | sops-encrypted secrets |
| `npins/sources.json` | Pins for buildbot-nix and niks3 |

## Key Design Decisions

### 1. fullyPrivate Mode

We use buildbot-nix's `accessMode.fullyPrivate` instead of configuring oauth2-proxy
separately. This mode:
- Automatically configures oauth2-proxy
- Sets up nginx proxying
- Configures `skip-auth-route` for `/change_hook` (webhooks)
- Handles internal basic auth between oauth2-proxy and buildbot

This simplifies our config and reduces potential for misconfiguration.

### 2. Single OAuth App

With `fullyPrivate` mode, we only need **one** GitHub OAuth App. The OAuth App
is used by oauth2-proxy for user authentication.

### 3. Webhook Path Remapping

GitHub App webhook URL: `https://ci.phlip9.com/webhooks/github-buildbot-ci`

This external path is remapped by nginx to buildbot's internal path:
```
/webhooks/github-buildbot-ci → oauth2-proxy → /change_hook/github → buildbot
```

oauth2-proxy's `skip-auth-route = [ "^/change_hook" ]` allows webhooks through
without authentication (they're verified by HMAC signature instead).

### 4. Flake Wrapper

buildbot-nix requires a `flake.nix` with a `.#checks` output. We added a minimal
wrapper that:
- Has no flake inputs (everything comes from `default.nix` via npins)
- Exposes `checks.${system}.{..}` for CI

## Configuration Reference

### Module Options

```nix
services.phlip9-buildbot-ci = {
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

### Required Secrets

All secrets in `nixos/omnara1/secrets.yaml`:

| Secret | Source |
|--------|--------|
| `niks3-s3-access-key` | Cloudflare R2 API token |
| `niks3-s3-secret-key` | Cloudflare R2 API token |
| `niks3-api-token` | `openssl rand -base64 48` |
| `niks3-signing-key` | `nix key generate-secret --key-name cache.phlip9.com-1` |
| `oauth2-proxy-client-secret` | GitHub OAuth App secret |
| `oauth2-proxy-cookie-secret` | `openssl rand -base64 32 \| tr -- '+/' '-_'` |
| `buildbot-http-basic-auth-password` | `openssl rand -base64 32` |
| `buildbot-nix-workers` | JSON: `[{"name":"omnara1","pass":"...","cores":10}]` |
| `buildbot-nix-worker-password` | Same password as in workers JSON |
| `buildbot-github-webhook-secret` | `openssl rand -hex 32` (set in GitHub App) |
| `buildbot-github-app-secret-key` | GitHub App private key (.pem file) |

### Generating Secrets

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Worker password ==="
WORKER_PASS=$(openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '=\n')
echo "$WORKER_PASS"

echo -e "\n=== Workers JSON ==="
echo "[{\"name\":\"omnara1\",\"pass\":\"$WORKER_PASS\",\"cores\":10}]"

echo -e "\n=== GitHub webhook secret ==="
openssl rand -hex 32

echo -e "\n=== niks3 API token ==="
openssl rand -base64 48 | tr -- '+/' '-_' | tr -d '=\n'

echo -e "\n=== niks3 signing key ==="
nix key generate-secret --key-name cache.phlip9.com-1 | tee key && echo ""

echo -e "\n=== niks3 signing pubkey (for nix clients) ==="
nix key convert-secret-to-public < key && echo ""

echo -e "\n=== oauth2-proxy cookie secret ==="
openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '=\n'

echo -e "\n=== buildbot http basic auth password ==="
openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '=\n'
```

## Setup Instructions

### GitHub App Setup

1. Go to <https://github.com/settings/apps/new>

2. **Basic info**:
   - Name: `phlip9-buildbot-ci`
   - Homepage: `https://ci.phlip9.com`

3. **Webhook**:
   - URL: `https://ci.phlip9.com/webhooks/github-buildbot-ci`
   - Secret: generate with `openssl rand -hex 32`

4. **Repository permissions**:
   - Contents: Read-only
   - Commit statuses: Read and write
   - Pull requests: Read-only

5. **Events**: Push, Pull request

6. After creation:
   - Note the App ID
   - Generate and download private key (.pem)
   - Install on `phlip9/dotfiles`

### GitHub OAuth App Setup

1. Go to https://github.com/settings/developers → OAuth Apps → New

2. Fill in:
   - Name: `phlip9-buildbot-oauth`
   - Homepage: `https://ci.phlip9.com`
   - Callback URL: `https://ci.phlip9.com/oauth2/callback`

3. Note Client ID, generate and save Client Secret

### Cloudflare R2 Setup

1. Create bucket `phlip9-nix-cache`
2. Connect custom domain `cache.phlip9.com`
3. Create API token with Object Read & Write on the bucket
4. Note Access Key ID and Secret Access Key

### Repository Setup

1. Add `buildbot-phlip9` topic to repo
2. Ensure `flake.nix` exists with `.#checks` output

## Concrete Values

**GitHub App** (`phlip9-buildbot-ci`):
- App ID: `2746100`

**GitHub OAuth App** (`phlip9-buildbot-oauth`):
- Client ID: `Ov23lipvJOGiZTG0aqv9`

**Cloudflare R2**:
- Bucket: `phlip9-nix-cache`
- Custom domain: `cache.phlip9.com`
- Account ID: `30faeb30dcb2a77a72fdc0948c99de62`
- S3 endpoint: `30faeb30dcb2a77a72fdc0948c99de62.r2.cloudflarestorage.com`

**Cache signing key** (public):
- `cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4=`

## Checklist

### Before deployment:
- [x] Create Cloudflare R2 bucket
- [x] Connect cache.phlip9.com domain
- [x] Create R2 API token
- [x] Create GitHub App
- [x] Create GitHub OAuth App
- [x] Generate all secrets
- [x] Encrypt secrets with sops
- [x] Add buildbot-nix + niks3 to npins
- [x] Create buildbot-ci.nix module
- [x] Add flake.nix with checks
- [x] Install GitHub App on phlip9/dotfiles
- [x] Add buildbot-phlip9 topic to repo

### After deployment:
- [ ] Verify ACME cert for ci.phlip9.com
- [ ] Test webhook delivery
- [ ] Test oauth2-proxy login
- [ ] Test cache uploads to R2
- [ ] Verify niks3-gc timer is active

## Adding New Repos

1. Add `buildbot-phlip9` topic to the repo
2. Install the `phlip9-buildbot-ci` GitHub App on the repo
3. Ensure repo has `flake.nix` with `.#checks.<system>.<name>` outputs
4. Push to trigger first build

## References

**Upstream**:
- <https://github.com/nix-community/buildbot-nix>
- <https://github.com/Mic92/niks3>

**Reference implementations**:
- `/home/phlip9/dev/buildbot-nix/examples/master.nix`
- `/home/phlip9/dev/mic92-dotfiles/machines/eve/modules/buildbot.nix`
