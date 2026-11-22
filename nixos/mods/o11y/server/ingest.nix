# o11y server: write-only ingest endpoints for remote collectors.
#
#   remote collector --HTTPS + basic auth--> nginx (existing vhost)
#     POST /o11y/metrics/api/v1/write   (vmagent)
#       -> VictoriaMetrics /api/v1/write?extra_label=instance=<username>
#     POST /o11y/profiles/push.v1.PusherService/Push   (Alloy)
#       -> Pyroscope, same path (if `server.profiling.enable`)
#     /o11y/* -> 404
#
# One htpasswd user per host (`username = hostname`); nginx pins sample
# `instance` to the username. Local collector still writes over loopback.
#
# Accepted risks (any valid credential can):
# - write profiles under any `host` label (Pyroscope lacks per-req override)
# - overwrite metric metadata (HELP/TYPE/UNIT) globally (VM ignores
#   `extra_label` on metadata)
#
# See: ../collector/default.nix
# See: doc/o11y/README.md
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.phlip9-o11y.server;
  cfgI = cfg.ingest;
  cfgVm = config.services.victoriametrics;
  cfgPyroSrv = config.services.pyroscope.settings.server;
  pyroscopeAddr =
    "${cfgPyroSrv.http_listen_address}:" + toString cfgPyroSrv.http_listen_port;

  inherit (import ../collector/lib.nix { inherit config; }) ingest;

  vhost = config.services.nginx.virtualHosts.${cfgI.vhost};
  httpsOnly = vhost.forceSSL || vhost.onlySSL;

  # Prevent Nix from copying secret path into store.
  htpasswdPath = toString cfgI.htpasswdFile;

  # 1 if basic auth username fails `ingest.usernameRegex` (set in http map).
  badUserVar = "$phlip9_o11y_ingest_bad_user";

  locationConfig = ''
    limit_except POST {
      deny all;
    }

    # Block non-hostname usernames in rewrite phase (before auth) to prevent
    # query injection into upstream URL.
    if (${badUserVar}) {
      return 403;
    }

    # Covers Alloy (~4 MiB split) + vmagent (<= 8 MiB uncompressed) batches.
    client_max_body_size 16m;
    # Keep typical bodies (~10 KiB - 1 MiB) in memory (allocates min(body, 1m)).
    client_body_buffer_size 1m;

    # Fail fast on loopback backends.
    proxy_connect_timeout 5s;
    # Must exceed Alloy's collectInterval (15s) so 504 doesn't trigger retries
    # of already-stored pushes; matches vmagent's 1m send timeout.
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;

    # Don't forward basic auth creds to backends.
    proxy_set_header Authorization "";
  '';
in
{
  options.services.phlip9-o11y.server.ingest = {
    enable = lib.mkEnableOption "write-only HTTPS ingest endpoints (/o11y/)";

    vhost = lib.mkOption {
      type = lib.types.str;
      example = "sauna.phlip9.com";
      description = ''
        Existing HTTPS-only nginx vhost (`forceSSL` or `onlySSL`) hosting
        `/o11y/` (basic auth sends passwords on every req). Collectors set
        `collector.remote.url = "https://<vhost>/o11y"`.
      '';
    };

    htpasswdFile = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression (
        "config.sops.secrets.o11y-ingest-htpasswd.path"
      );
      description = ''
        htpasswd file (secret) w/ `<username>:<hash>` per collector host
        (matching `${ingest.usernameRegex}`; username stamps sample `instance`).
        Must be readable by `services.nginx.user` (re-read per req; no reload
        needed). Use sha512-crypt (`$6$` via `openssl passwd -6`; NixOS
        libxcrypt omits `$5$`).
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfgI.enable) {
    assertions = [
      {
        assertion = config.services.nginx.enable && httpsOnly;
        message = ''
          phlip9-o11y: server.ingest.vhost "${cfgI.vhost}" must be an
          HTTPS-only nginx vhost (forceSSL or onlySSL): basic auth sends the
          password in every request.
        '';
      }
    ];

    # Allow hostnames or empty (unauthenticated -> 401; nginx rejects empty
    # usernames during auth).
    services.nginx.appendHttpConfig = ''
      map $remote_user ${badUserVar} {
        default 1;
        "" 0;
        "~${ingest.usernameRegex}" 0;
      }
    '';

    services.nginx.virtualHosts.${cfgI.vhost}.locations = {
      # 404 unknown paths under prefix w/o auth; ^~ beats regex locations.
      "^~ ${ingest.prefix}/".return = "404";

      "= ${ingest.prefix}${ingest.metricsPath}" = {
        # Variables in proxyPass drop client query string and pin instance.
        proxyPass = "http://${cfgVm.listenAddress}/api/v1/write?extra_label=instance=$remote_user";
        basicAuthFile = htpasswdPath;
        extraConfig = locationConfig;
      };

      "= ${ingest.prefix}${ingest.profilesPath}${ingest.pushProcedure}" =
        lib.mkIf cfg.profiling.enable
          {
            proxyPass = "http://${pyroscopeAddr}${ingest.pushProcedure}";
            basicAuthFile = htpasswdPath;
            extraConfig = locationConfig + ''
              # Variable-free proxy_pass appends client query string; strip it.
              set $args "";
              # Strip tenant header in case multitenancy is ever enabled.
              proxy_set_header X-Scope-OrgID "";
            '';
          };
    };
  };
}
