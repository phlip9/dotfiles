# Buildbot CI Research Summary for omnara1

Research completed 2025-01-28.

## Overview

Setting up buildbot-nix CI on omnara1 (Hetzner 6c/12t server) to build:
- `phlip9/dotfiles` master + PRs (initial)
- Extensible to more repos later

Components:
- **buildbot-nix**: NixOS module for buildbot CI with Nix
- **niks3**: S3-backed binary cache with GC (using Cloudflare R2)
- **oauth2-proxy**: Protect web UI (allow only `phlip9`, `lexe-agent`)

## Architecture

```
GitHub webhook (/webhooks/github-buildbot-ci)
    │
    ▼
nginx (ci.phlip9.com:443)
    │
    ├─► oauth2-proxy ([::1]:4180) ─► buildbot-master ([::1]:8010)
    │                                    │
    │                                    ▼
    │                                buildbot-worker
    │                                    │
    │                                    ▼ (post-build)
    │                                niks3 push
    │                                    │
    │                                    ▼
    └─► niks3 server ([::1]:5751) ─► Cloudflare R2
                                         │
                                         ▼
                                cache.phlip9.com (public reads)
```

## Local Paths

**Checked-out repos** (cloned during research):
- `/home/phlip9/dev/buildbot-nix` - buildbot-nix upstream
- `/home/phlip9/dev/niks3` - niks3 upstream
- `/home/phlip9/dev/mic92-dotfiles` - Mic92's dotfiles (reference)
- `/home/phlip9/dev/doctor-cluster-config` - TUM-DSE config (reference)
- `/home/phlip9/dev/oauth2-proxy` - oauth2-proxy upstream

**nixpkgs** (from npins):
- `/nix/store/5gs5kzcpavjvm25896hp7frik1zzj73c-source` (nixos-unstable)

## Key Files

| Component | Upstream Module | Reference Implementation |
|-----------|-----------------|-------------------------|
| buildbot master | `/home/phlip9/dev/buildbot-nix/nixosModules/master.nix` | `/home/phlip9/dev/mic92-dotfiles/machines/eve/modules/buildbot.nix` |
| buildbot worker | `/home/phlip9/dev/buildbot-nix/nixosModules/worker.nix` | same |
| niks3 | `/home/phlip9/dev/niks3/nix/nixosModules/niks3.nix` | `/home/phlip9/dev/doctor-cluster-config/modules/niks3/` |
| oauth2-proxy | `/nix/store/5gs5kzcpavjvm25896hp7frik1zzj73c-source/nixos/modules/services/security/oauth2-proxy.nix` | - |

**Additional reference files**:
- `/home/phlip9/dev/buildbot-nix/docs/GITHUB.md` - GitHub App setup docs
- `/home/phlip9/dev/buildbot-nix/examples/master.nix` - example master config
- `/home/phlip9/dev/buildbot-nix/examples/worker.nix` - example worker config
- `/home/phlip9/dev/niks3/README.md` - niks3 usage docs
- `/home/phlip9/dev/doctor-cluster-config/modules/niks3/reverse-proxy.nix` - S3 proxy pattern

## 1. buildbot-nix

### How it works

1. GitHub App receives webhooks for push/PR events
2. Master schedules `nix-eval` job to discover build targets
3. Evaluates `flake.nix` `.#checks` (or custom attribute)
4. Spawns individual build jobs for each derivation
5. Reports status back to GitHub via API

### GitHub App Setup (Step-by-Step)

See also: `/home/phlip9/dev/buildbot-nix/docs/GITHUB.md`

1. Go to https://github.com/settings/apps/new

2. **Basic info**:
   - GitHub App name: `phlip9-buildbot-ci` (must be globally unique)
   - Homepage URL: `https://ci.phlip9.com`

3. **Webhook**:
   - Webhook URL: `https://ci.phlip9.com/webhooks/github-buildbot-ci`
   - Webhook secret: generate with `openssl rand -hex 32` (save for later)

4. **Repository permissions**:
   - Contents: Read-only
   - Commit statuses: Read and write
   - Pull requests: Read-only
   - Metadata: Read-only (automatically selected)

5. **Subscribe to events**:
   - Push
   - Pull request

6. **Where can this GitHub App be installed?**: Only on this account

7. Click "Create GitHub App"

8. **After creation**:
   - Note the **App ID** (numeric, shown at top)
   - Scroll to "Private keys" → "Generate a private key"
   - Download the `.pem` file (this is `buildbot-github-app-secret-key`)

9. **Install the app**:
   - Left sidebar → "Install App"
   - Select your account → Install
   - Choose "Only select repositories" → select `phlip9/dotfiles`

### GitHub OAuth App Setup (for web UI login)

1. Go to https://github.com/settings/developers → OAuth Apps → New OAuth App

2. Fill in:
   - Application name: `phlip9-buildbot-oauth`
   - Homepage URL: `https://ci.phlip9.com`
   - Authorization callback URL: `https://ci.phlip9.com/oauth2/callback`

3. Click "Register application"

4. Note the **Client ID**

5. Click "Generate a new client secret"
   - Copy immediately (shown only once) - this is `buildbot-github-oauth-secret`

### Required Secrets

```
buildbot-nix-workers            # JSON: [{"name": "omnara1", "pass": "...", "cores": 10}]
buildbot-github-webhook-secret  # hex string from App setup step 3
buildbot-github-app-secret-key  # .pem file contents from App setup step 8
buildbot-github-oauth-secret    # OAuth app secret from OAuth setup step 5
buildbot-nix-worker-password    # random string, must match workers JSON
```

**Generating secrets**:
```bash
# Webhook secret (hex)
openssl rand -hex 32

# Worker password (base64, URL-safe)
openssl rand -base64 32 | tr -- '+/' '-_'

# Workers JSON (use same password as above)
cat > /tmp/workers.json << 'EOF'
[{"name": "omnara1", "pass": "PASTE_WORKER_PASSWORD_HERE", "cores": 10}]
EOF
```

### NixOS Config Skeleton

```nix
services.buildbot-nix.master = {
  enable = true;
  domain = "ci.phlip9.com";
  workersFile = config.sops.secrets.buildbot-nix-workers.path;

  buildSystems = [ "x86_64-linux" ];
  evalWorkerCount = 4;  # tune for 6c/12t

  github = {
    appId = <APP_ID>;  # numeric ID from GitHub App page
    appSecretKeyFile = config.sops.secrets.buildbot-github-app-secret-key.path;
    webhookSecretFile = config.sops.secrets.buildbot-github-webhook-secret.path;
    oauthId = "<OAUTH_CLIENT_ID>";  # from OAuth App page
    oauthSecretFile = config.sops.secrets.buildbot-github-oauth-secret.path;

    # Only build repos with this topic (add to phlip9/dotfiles)
    topic = "buildbot-phlip9";
    # Or explicit user allowlist
    userAllowlist = [ "phlip9" ];
  };

  admins = [ "phlip9" ];
  outputsPath = "/var/www/buildbot/nix-outputs/";

  niks3 = {
    enable = true;
    serverUrl = "http://[::1]:5751";
    authTokenFile = config.sops.secrets.niks3-api-token.path;
  };
};

services.buildbot-nix.worker = {
  enable = true;
  workerPasswordFile = config.sops.secrets.buildbot-nix-worker-password.path;
};
```

### For non-flake repos (phlip9/dotfiles)

Option A: Add thin `flake.nix` wrapper exposing `.#checks`
Option B: Use pull-based polling with explicit config

## 2. niks3 (S3-backed binary cache)

### How it works

- **Write path**: buildbot calls `niks3 push` → server generates presigned S3 URLs → client uploads directly to R2
- **Read path**: Nix clients fetch directly from S3/R2 via public URL
- PostgreSQL tracks references for garbage collection
- Ed25519 signing for narinfo integrity

### Cloudflare R2 Setup (Step-by-Step)

**R2 Benefits**: Zero egress fees (huge for binary cache)

1. **Create R2 bucket**:
   - Log into Cloudflare dashboard → R2 Object Storage
   - Click "Create bucket"
   - Bucket name: `phlip9-nix-cache`
   - Location hint: choose closest region (e.g., Western Europe for Hetzner)
   - Click "Create bucket"

2. **Enable public access** (for nix client reads):
   - Click on the bucket → Settings tab
   - Under "Public access", click "Allow Access"
   - Either use R2.dev subdomain or connect custom domain
   - **Recommended**: Connect `cache.phlip9.com` as custom domain
     - Click "Connect Domain"
     - Enter `cache.phlip9.com`
     - Cloudflare will configure DNS automatically

3. **Create API token** (for niks3 writes):
   - R2 Object Storage → Manage R2 API Tokens
   - Click "Create API token"
   - Token name: `niks3-omnara1`
   - Permissions: Object Read & Write
   - Specify bucket: `phlip9-nix-cache` (more secure than all buckets)
   - TTL: No expiration (or set reminder to rotate)
   - Click "Create API Token"
   - **COPY IMMEDIATELY** (shown only once):
     - Access Key ID → `niks3-s3-access-key`
     - Secret Access Key → `niks3-s3-secret-key`

4. **Note your Account ID**:
   - Visible in URL: `dash.cloudflare.com/<ACCOUNT_ID>/...`
   - Or: R2 Overview page shows it
   - S3 endpoint will be: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`

### Generate Signing Key

```bash
# Generate secret key (contains both private and public parts)
nix key generate-secret --key-name cache.phlip9.com-1

# Output format: cache.phlip9.com-1:BASE64_SECRET_KEY
# Save entire output as niks3-signing-key

# Extract public key (for nix.conf trusted-public-keys)
echo "cache.phlip9.com-1:BASE64_SECRET_KEY" | nix key convert-secret-to-public
# Output: cache.phlip9.com-1:BASE64_PUBLIC_KEY
# Save public key for documentation/client config
```

### Generate API Token

```bash
# niks3 API token (min 36 chars, used for Bearer auth)
openssl rand -base64 48
# Save as niks3-api-token
```

### Required Secrets

```
niks3-s3-access-key   # R2 Access Key ID (from step 3)
niks3-s3-secret-key   # R2 Secret Access Key (from step 3)
niks3-api-token       # Bearer token for push auth (generated above)
niks3-signing-key     # Ed25519 key: cache.phlip9.com-1:BASE64 (generated above)
```

### NixOS Config

```nix
services.niks3 = {
  enable = true;
  httpAddr = "[::1]:5751";
  cacheUrl = "https://cache.phlip9.com";

  s3 = {
    endpoint = "<ACCOUNT_ID>.r2.cloudflarestorage.com";
    bucket = "phlip9-nix-cache";
    useSSL = true;
    accessKeyFile = config.sops.secrets.niks3-s3-access-key.path;
    secretKeyFile = config.sops.secrets.niks3-s3-secret-key.path;
  };

  apiTokenFile = config.sops.secrets.niks3-api-token.path;
  signKeyFiles = [ config.sops.secrets.niks3-signing-key.path ];

  # GC settings
  gc.enable = true;
  gc.olderThan = "720h";  # 30 days
  gc.schedule = "daily";

  # Optional: GitHub Actions OIDC for external pushes
  # oidc.providers.github = { ... };
};
```

### Public Cache Access

If using R2 custom domain (`cache.phlip9.com`), Cloudflare handles TLS and
routing automatically. No nginx config needed for the cache itself.

Nix clients configure:
```nix
nix.settings = {
  extra-substituters = [ "https://cache.phlip9.com" ];
  extra-trusted-public-keys = [ "cache.phlip9.com-1:BASE64_PUBLIC_KEY" ];
};
```

## 3. oauth2-proxy

Protects buildbot web UI, only allows `phlip9` and `lexe-agent`.

**Note**: We already created a GitHub OAuth App in the buildbot section above
for buildbot's internal auth. For oauth2-proxy we need a **separate** OAuth App
with a different callback URL.

### GitHub OAuth App Setup (for oauth2-proxy)

1. Go to https://github.com/settings/developers → OAuth Apps → New OAuth App

2. Fill in:
   - Application name: `phlip9-ci-oauth2-proxy`
   - Homepage URL: `https://ci.phlip9.com`
   - Authorization callback URL: `https://ci.phlip9.com/oauth2/callback`

3. Click "Register application"

4. Note the **Client ID**

5. Click "Generate a new client secret"
   - Copy immediately - this is `oauth2-proxy-client-secret`

### Generate Cookie Secret

```bash
# 32-byte base64 URL-safe (required for AES encryption)
openssl rand -base64 32 | tr -- '+/' '-_'
# Save as oauth2-proxy-cookie-secret
```

### Required Secrets

```
oauth2-proxy-client-secret   # from OAuth App step 5
oauth2-proxy-cookie-secret   # generated above
```

### NixOS Config

```nix
services.oauth2-proxy = {
  enable = true;
  provider = "github";

  clientID = "<OAUTH2_PROXY_CLIENT_ID>";  # from OAuth App step 4
  keyFile = config.sops.secrets.oauth2-proxy-env.path;
  # keyFile contains (env var format):
  # OAUTH2_PROXY_CLIENT_SECRET=...
  # OAUTH2_PROXY_COOKIE_SECRET=...

  redirectURL = "https://ci.phlip9.com/oauth2/callback";

  # Restrict to specific GitHub users
  extraConfig = {
    github-user = "phlip9,lexe-agent";
    skip-provider-button = "true";  # auto-redirect to GitHub
  };

  upstream = [ "http://[::1]:8010/" ];
  httpAddress = "http://[::1]:4180";

  cookie = {
    secure = true;
    httpOnly = true;
  };

  passBasicAuth = true;  # sends X-Forwarded-User to buildbot
};
```

### nginx Integration

```nix
services.nginx.virtualHosts."ci.phlip9.com" = {
  forceSSL = true;
  enableACME = true;

  locations."/" = {
    proxyPass = "http://[::1]:4180";
  };

  # WebSocket for buildbot live updates
  locations."/ws" = {
    proxyPass = "http://[::1]:4180";
    proxyWebsockets = true;
    extraConfig = "proxy_read_timeout 6000s;";
  };

  # SSE for live updates
  locations."/sse" = {
    proxyPass = "http://[::1]:4180";
    extraConfig = "proxy_buffering off;";
  };

  # GitHub webhook bypasses oauth2-proxy (uses HMAC verification)
  locations."/webhooks/github-buildbot-ci" = {
    proxyPass = "http://[::1]:8010/change_hook/github";
  };
};
```

## 4. Secrets Summary

All via sops-nix + systemd LoadCredential.

### Complete Secrets Checklist

Generate/obtain each secret, then encrypt with sops:

| Secret | How to Generate | Notes |
|--------|-----------------|-------|
| `buildbot-nix-workers` | Manual JSON | `[{"name":"omnara1","pass":"...","cores":10}]` |
| `buildbot-nix-worker-password` | `openssl rand -base64 32` | Must match password in workers JSON |
| `buildbot-github-webhook-secret` | `openssl rand -hex 32` | Set in GitHub App webhook config |
| `buildbot-github-app-secret-key` | Download from GitHub | `.pem` file contents |
| `buildbot-github-oauth-secret` | Copy from GitHub | Shown once when generating |
| `niks3-s3-access-key` | Copy from Cloudflare | R2 API token Access Key ID |
| `niks3-s3-secret-key` | Copy from Cloudflare | R2 API token Secret |
| `niks3-api-token` | `openssl rand -base64 48` | For buildbot→niks3 auth |
| `niks3-signing-key` | `nix key generate-secret --key-name cache.phlip9.com-1` | Full output |
| `oauth2-proxy-client-secret` | Copy from GitHub | OAuth App secret |
| `oauth2-proxy-cookie-secret` | `openssl rand -base64 32 \| tr -- '+/' '-_'` | Must be URL-safe base64 |

### secrets.yaml Structure

```yaml
# nixos/omnara1/secrets.yaml
# Buildbot
buildbot-nix-workers: ENC[...]
buildbot-nix-worker-password: ENC[...]
buildbot-github-webhook-secret: ENC[...]
buildbot-github-app-secret-key: ENC[...]
buildbot-github-oauth-secret: ENC[...]

# niks3 / R2
niks3-s3-access-key: ENC[...]
niks3-s3-secret-key: ENC[...]
niks3-api-token: ENC[...]
niks3-signing-key: ENC[...]

# oauth2-proxy (env file format for keyFile)
oauth2-proxy-env: ENC[...]
# Contents:
# OAUTH2_PROXY_CLIENT_SECRET=...
# OAUTH2_PROXY_COOKIE_SECRET=...
```

### Quick Generation Script

Run locally, copy values into secrets.yaml:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Worker password ==="
WORKER_PASS=$(openssl rand -base64 32 | tr -- '+/' '-_')
echo "$WORKER_PASS"

echo -e "\n=== Workers JSON ==="
echo "[{\"name\":\"omnara1\",\"pass\":\"$WORKER_PASS\",\"cores\":10}]"

echo -e "\n=== GitHub webhook secret ==="
openssl rand -hex 32

echo -e "\n=== niks3 API token ==="
openssl rand -base64 48

echo -e "\n=== niks3 signing key ==="
nix key generate-secret --key-name cache.phlip9.com-1

echo -e "\n=== oauth2-proxy cookie secret ==="
openssl rand -base64 32 | tr -- '+/' '-_'

echo -e "\n=== Public key (for nix clients) ==="
echo "Run: echo 'SIGNING_KEY' | nix key convert-secret-to-public"
```

## 5. Implementation Plan

### Phase 1: Infrastructure
1. Add buildbot-nix + niks3 flake inputs (or npins)
2. Create Cloudflare R2 bucket
3. Generate all secrets, encrypt with sops
4. Create GitHub App for buildbot
5. Create GitHub OAuth App for oauth2-proxy

### Phase 2: NixOS Module
1. Create `nixos/mods/buildbot-ci.nix` module
2. Configure niks3 with R2 backend
3. Configure buildbot-nix master + worker
4. Configure oauth2-proxy
5. Configure nginx virtual hosts

### Phase 3: Repository Setup
1. Add `flake.nix` to dotfiles exposing `.#checks`
2. Add `buildbot-phlip9` topic to repo
3. Install GitHub App on repo

### Phase 4: Testing & Polish
1. Test webhook delivery
2. Test build + cache flow
3. Verify oauth2-proxy restricts access
4. Document adding new repos

## 6. Resource Tuning (6c/12t)

```nix
services.buildbot-nix.master = {
  evalWorkerCount = 4;    # parallel nix-eval-jobs
  buildSystems = [ "x86_64-linux" ];
};

# Workers JSON
[{"name": "omnara1", "pass": "...", "cores": 10}]

# Reserve 2 cores for master/eval/system
```

## Appendix A: Concrete Values

**GitHub App** (`phlip9-buildbot-ci`):
- App ID: `2746100`
- Client ID: `Iv23liE6dM8w5D4JF7Qz`

**GitHub OAuth App** (`phlip9-buildbot-oauth`, for buildbot web UI auth):
- Client ID: `Ov23lipvJOGiZTG0aqv9`

**GitHub OAuth App** (`phlip9-ci-oauth2-proxy`, for oauth2-proxy):
- Client ID: `Ov23liO4sP0FzyZ3QmO5`

**Cloudflare R2**:
- Bucket: `phlip9-nix-cache`
- Custom domain: `cache.phlip9.com`
- Account ID: `30faeb30dcb2a77a72fdc0948c99de62`
- S3 endpoint: `30faeb30dcb2a77a72fdc0948c99de62.r2.cloudflarestorage.com`

**niks3 signing key** (public, for nix clients):
- `cache.phlip9.com-1:XKElS8qFXxVXcXIGFjRkGpyxiernJzHeQhMJ59VUdf4=`

## Appendix B: Manual Steps Checklist

### Before deployment:

- [x] Create Cloudflare R2 bucket `phlip9-nix-cache`
- [x] Connect `cache.phlip9.com` as R2 custom domain
- [x] Create R2 API token, save credentials
- [x] Create GitHub App `phlip9-buildbot-ci`
- [x] Download GitHub App private key (.pem)
- [ ] Install GitHub App on `phlip9/dotfiles`
- [x] Create GitHub OAuth App for buildbot auth
- [x] Create GitHub OAuth App for oauth2-proxy
- [x] Generate all local secrets (see script above)
- [x] Encrypt secrets with sops
- [ ] Add `buildbot-phlip9` topic to `phlip9/dotfiles`

### After deployment:

- [ ] Test webhook delivery (push to repo, check buildbot)
- [ ] Test oauth2-proxy login (access ci.phlip9.com)
- [ ] Test cache (build something, check R2 bucket)
- [ ] Verify GC timer is active

## References

**Upstream repos**:
- buildbot-nix: https://github.com/nix-community/buildbot-nix
- niks3: https://github.com/Mic92/niks3
- oauth2-proxy: https://github.com/oauth2-proxy/oauth2-proxy

**Local clones** (for code reference):
- `/home/phlip9/dev/buildbot-nix`
- `/home/phlip9/dev/niks3`
- `/home/phlip9/dev/oauth2-proxy`

**Reference implementations**:
- `/home/phlip9/dev/mic92-dotfiles/machines/eve/modules/buildbot.nix`
- `/home/phlip9/dev/mic92-dotfiles/machines/eve/modules/harmonia.nix`
- `/home/phlip9/dev/doctor-cluster-config/modules/buildbot/`
- `/home/phlip9/dev/doctor-cluster-config/modules/niks3/`

**nixpkgs** (from npins):
- `/nix/store/5gs5kzcpavjvm25896hp7frik1zzj73c-source`
