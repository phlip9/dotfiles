# o11y server: write-only ingest endpoints for remote collectors.
#
#   remote collector --HTTPS + basic auth--> nginx, on an existing vhost
#     POST /o11y/metrics/api/v1/write   (vmagent)
#       -> VictoriaMetrics /api/v1/write?extra_label=instance=<username>
#     POST /o11y/profiles/push.v1.PusherService/Push   (Alloy)
#       -> Pyroscope, same path (if `server.profiling.enable`)
#     anything else under /o11y/ -> 404
#
# One htpasswd credential per collector host, username = its hostname,
# for both endpoints. nginx pins the samples' `instance` label to the
# username, so a host can only write samples as itself. Accepted risks, a
# valid credential can still:
# - write profiles under any `host` label: Pyroscope has no per-request
#   label override w/o tenants
# - replace any metric family's metadata (HELP, TYPE, UNIT), for all hosts:
#   VictoriaMetrics stores remote write metadata w/o `extra_label`.
#   Cosmetic, and Grafana uses it.
#
# This host's own collector writes over loopback, w/o auth, not through
# here (see ../collector/default.nix).
#
# How each request trick is blocked:
# - other paths, incl. `..`, `//`, `%2F`: nginx matches locations against
#   the decoded + normalized path. Only two exact (`=`) locations proxy,
#   each to a fixed upstream path. The rest of the prefix is a 404.
# - client query string: replaced. A `proxy_pass` URL w/ variables is
#   sent as is, w/o the client's args; else `$args` is cleared.
# - spoofed `instance` in the body: VictoriaMetrics appends `extra_label`
#   after the series' own labels, and the last duplicate label wins
#   (lib/storage/metric_name.go `sortTags`).
# - other methods: `limit_except POST`, 403.
#
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

  # A string: a path literal must not get copied into the store
  htpasswdPath = toString cfgI.htpasswdFile;

  # nginx variable: 1 if the request's basic auth username isn't a plain
  # hostname (see `ingest.usernameRegex`), set in the http block below.
  badUserVar = "$phlip9_o11y_ingest_bad_user";

  # Shared by both ingest locations.
  locationConfig = ''
    # Only POST. GET (incl. HEAD), PUT, ... -> 403.
    limit_except POST {
      deny all;
    }

    # Reject usernames that aren't plain hostnames, so they can't inject
    # query args into the upstream URL. Runs before auth (rewrite phase),
    # on the username from the request, which auth then checks.
    if (${badUserVar}) {
      return 403;
    }

    # A batch of profiles: a collect interval's worth, split at ~4 MiB
    # (nixos/pkgs/grafana-alloy). vmagent blocks: <= 8 MiB uncompressed.
    # The vhost's own limit may be lower.
    client_max_body_size 16m;
    # nginx reads the body before proxying (request buffering), so a slow
    # client never ties up a backend request. Typical bodies are ~10 KiB
    # (vmagent) to ~1 MiB (a profile batch) and stay in memory. Bigger ones
    # spill to a temp file w/ a warning. Only allocates min(body, this).
    client_body_buffer_size 1m;

    # Backends are on loopback: fail fast.
    proxy_connect_timeout 5s;
    # > Alloy's push deadline (`collector.profiling.collectInterval`, 15s):
    # a proxy timeout (504) is retried by Alloy, a push that may already
    # be stored. vmagent's send timeout is 1m; VictoriaMetrics acks at once.
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;

    # The backends don't check credentials: don't hand them out.
    proxy_set_header Authorization "";
  '';
in
{
  options.services.phlip9-o11y.server.ingest = {
    enable = lib.mkEnableOption ''
      write-only HTTPS endpoints for remote collectors
      (`collector.remote`) under `/o11y/` on the nginx vhost `vhost`:
      VictoriaMetrics remote write + Pyroscope push, nginx basic auth
    '';

    vhost = lib.mkOption {
      type = lib.types.str;
      example = "sauna.phlip9.com";
      description = ''
        Existing nginx vhost (`services.nginx.virtualHosts.<name>`) to add
        the ingest locations to. Must be HTTPS-only (`forceSSL` or
        `onlySSL`): basic auth sends the password w/ every request. Its
        `http2` (nixpkgs default: on) lets Alloy multiplex pushes.
        Collectors use `https://<vhost>/o11y` as `collector.remote.url`.
      '';
    };

    htpasswdFile = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression (
        "config.sops.secrets.o11y-ingest-htpasswd.path"
      );
      description = ''
        htpasswd file w/ one `<username>:<hash>` line per collector host,
        username = its `collector.remote.username` (default: hostname),
        matching `${ingest.usernameRegex}`. The username becomes the
        `instance` label of every sample it writes (not of metric metadata
        or profiles, see nixos/mods/o11y/server/ingest.nix).

        nginx workers read it on every request, so it must be readable by
        `services.nginx.user`, ex: sops `owner = config.services.nginx.user`.
        Changes apply w/o a reload.

        Hash: sha512-crypt (`$6$`, default rounds), checked w/ crypt(3).
        A standard scheme; the passwords are long random tokens anyway.
        nginx checks it on every request, w/o a cache: ~3ms CPU each
        (measured), negligible at ~10 requests/min per host. NixOS'
        libxcrypt has no sha256-crypt (`$5$`): only "strong" hashes.
        Generate an entry for host `phlipdesk` w/ its password in the
        file `password`:

            echo "phlipdesk:$(openssl passwd -6 -stdin < password)"
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

    # Plain hostnames, or no username yet (auth answers 401). Usernames
    # can't be empty once authenticated: nginx rejects `:<password>`.
    services.nginx.appendHttpConfig = ''
      map $remote_user ${badUserVar} {
        default 1;
        "" 0;
        "~${ingest.usernameRegex}" 0;
      }
    '';

    services.nginx.virtualHosts.${cfgI.vhost}.locations = {
      # Everything else under the prefix. `^~`: no regex location wins.
      # No auth: unknown paths 404 w/o a password check.
      "^~ ${ingest.prefix}/".return = "404";

      "= ${ingest.prefix}${ingest.metricsPath}" = {
        # Sent as is (variables in the URL): the client's query string is
        # dropped, `instance` = the authenticated username.
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
              # A `proxy_pass` URL w/o variables appends the client's query
              # string.
              set $args "";
              # Pyroscope w/o multitenancy ignores it. If that ever changes,
              # clients still can't pick their tenant.
              proxy_set_header X-Scope-OrgID "";
            '';
          };
    };
  };
}
