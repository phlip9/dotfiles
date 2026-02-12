# Lazy-loaded PostgreSQL home-manager service tuned for integration tests
#
# Connect via: `PGHOST=$XDG_RUNTIME_DIR`
#
# 1. Use `systemd` socket activation and `systemd-socket-proxyd` to make
#    postgres lazy load on-demand only when needed. The DB then spins down
#    after 10 min of inactivity.
# 2. Tune the DB for running integration tests with max speed and min
#    safety+durability.
#
# DO NOT USE THIS IS IN PRODUCTION.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkIf
    mkOption
    optionalString
    types
    ;

  cfg = config.services.postgres;
  pkg = cfg.package;
  # isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

  postgresqlConf = pkgs.writeTextDir "postgresql.conf" ''
    # Connection settings
    listen_addresses = ''' # Only allow connections via unix socket
    unix_socket_permissions = 0700
    ssl = off
    max_connections = 64

    # Remove brakes
    fsync = off
    synchronous_commit = off
    full_page_writes = off
    commit_delay = 0
    commit_siblings = 0
    wal_sync_method = open_sync  # (allegedly) fastest method when fsync is off

    # WAL settings
    wal_level = minimal                 # minimal WAL logging
    max_wal_senders = 0                 # no replication
    wal_buffers = 64MB                  # larger WAL buffer for faster writes
    checkpoint_timeout = 60min          # infrequent checkpoints
    checkpoint_completion_target = 0.9  # spread checkpoint writes
    max_wal_size = 2GB                  # max size of WAL files
    min_wal_size = 1GB                  # min size of WAL files
    wal_compression = off

    # Tune resource usage
    shared_buffers = 2GB          # cache for frequently accessed data
    work_mem = 16MB               # memory for sorts, hashes, and joins
    maintenance_work_mem = 256MB  # for VACUUM, CREATE INDEX, ALTER TABLE, etc.
    temp_buffers = 32MB           # for temporary tables
    effective_cache_size = 4GB    # hint for query planner

    # Tune query planner
    random_page_cost = 1.0          # assume everything is in memory
    effective_io_concurrency = 200  # NVMe can handle lots of concurrent I/O
    seq_page_cost = 1.0             # sequential read cost
    jit = off                       # disable JIT compilation

    # Autovacuum - run only when idle
    autovacuum = on
    autovacuum_max_workers = 2            # Fewer workers when active
    autovacuum_naptime = 5min             # Check more frequently when idle
    autovacuum_vacuum_threshold = 1000    # Higher threshold
    autovacuum_analyze_threshold = 1000   # Higher threshold
    autovacuum_vacuum_scale_factor = 0.4  # Less aggressive
    autovacuum_analyze_scale_factor = 0.2 # Less aggressive
    autovacuum_vacuum_cost_delay = 10ms   # Slower when it runs
    autovacuum_vacuum_cost_limit = 1000   # Limit vacuum impact

    # Background writer - more aggressive when idle
    bgwriter_delay = 1000ms     # Check more frequently
    bgwriter_lru_maxpages = 0   # Disable LRU writes
    bgwriter_flush_after = 0    # Disable flush-after
    backend_flush_after = 0     # Disable backend flush

    # Statement
    statement_timeout = 10s                    # kill long-running test queries
    lock_timeout = 10s                         # don't wait long for locks
    idle_in_transaction_session_timeout = 10s  # kill idle transactions

    # Reduce logging
    log_destination = 'stderr'
    log_line_prefix = '''
    logging_collector = off             # systemd will handle logs
    log_statement = 'none'              # don't log statements
    log_duration = off                  # don't log statement duration
    log_lock_waits = on                 # debug deadlocks
    log_error_verbosity = terse
    log_connections = off
    log_disconnections = off
    log_hostname = off
    log_min_messages = warning          # Only log warnings and errors
    log_checkpoints = off               # Don't log checkpoint activity
    log_autovacuum_min_duration = 10s   # Only log slow autovacuum
  '';

  pgHbaConf = pkgs.writeTextDir "pg_hba.conf" ''
    # Type  DB   User          Addr       Method

    # Only local connections
    local   all  ${config.home.username}  peer
    local   all  all                      reject
  '';

  shellHook = ''
    export PGHOST=$XDG_RUNTIME_DIR
  '';
in
{
  options = {
    services.postgres = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable PostgreSQL";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.postgresql_17;
        description = "PostgreSQL package to use";
      };

      dataDir = mkOption {
        type = types.path;
        default = "${config.xdg.dataHome}/postgres/${pkg.psqlSchema}";
        description = "Directory for PostgreSQL data files";
      };

      initdbArgs = mkOption {
        type = types.listOf types.str;
        default = [
          "--encoding=UTF8"
          "--locale=C"
        ];
        description = ''
          Arguments to pass to initdb. For example, you can set
          `initdbArgs = [ "--encoding=UTF8" ]` to set the encoding.
        '';
      };

      initialScript = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = literalExpression ''
          pkgs.writeText "init-sql-script" '''
            alter user postgres with password 'myPassword';
          ''';'';

        description = ''
          A file containing SQL statements to execute on first startup.
        '';
      };

      ensureDatabases = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Ensures that the specified databases exist.
          This option will never delete existing databases, especially not when the value of this
          option is changed. This means that databases created once through this option or
          otherwise have to be removed manually.
        '';
        example = [
          "gitea"
          "nextcloud"
        ];
      };
    };
  };

  config = mkIf cfg.enable {
    # include postgres bins in $PATH
    home.packages = [ pkg ];

    # set `PGHOST` so `psql` et al. just works
    home.sessionVariablesExtra = shellHook;
    programs.bash.initExtra = shellHook;

    # Linux systemd user service
    systemd.user = mkIf isLinux {
      services.postgres = {
        Unit = {
          Description = "PostgreSQL v${pkg.version} DB server";
          # Stop when `proxy-to-postgres.service` stops due to inactivity
          StopWhenUnneeded = true;
        };

        Service = {
          Type = "notify";

          Environment = [
            "PATH=${
              lib.makeBinPath [
                pkg
                pkgs.coreutils
                pkgs.gnugrep
              ]
            }"
            "PGDATA=${cfg.dataDir}"
            "PGHOST=%t/postgres"
          ];

          ExecStartPre =
            let
              script = pkgs.writeShellScript "postgres-pre-start" ''
                set -euo pipefail

                mkdir -p "$PGDATA" && chmod 700 "$PGDATA"
                mkdir -p "$PGHOST" && chmod 700 "$PGHOST"

                if [[ ! -e "$PGDATA/PG_VERSION" ]]; then
                  # cleanup the data dir
                  rm -f "$PGDATA/*.conf"

                  # init the database
                  initdb ${builtins.concatStringsSep " " cfg.initdbArgs} -D "$PGDATA"

                  # See ExecStartPost
                  touch "$PGDATA/.first_startup"
                fi

                ln -sfn "${postgresqlConf}/postgresql.conf" "$PGDATA/postgresql.conf"
                ln -sfn "${pgHbaConf}/pg_hba.conf" "$PGDATA/pg_hba.conf"
              '';
            in
            "+${script}";

          ExecStart = "${pkg}/bin/postgres --unix_socket_directories=%t/postgres";

          ExecStartPost =
            let
              script = pkgs.writeShellScript "postgres-post-start" ''
                set -euo pipefail

                # wait for the postgres to be ready
                pg_isready -d template1 --timeout=15

                # run the initial script on first startup if set
                if [[ -e "$PGDATA/.first_startup" ]]; then
                  ${optionalString (
                    cfg.initialScript != null
                  ) "psql -d postgres -f \"${cfg.initialScript}\""}
                  rm "$PGDATA/.first_startup"
                fi

                # ensure databases exist
                for db in ${lib.concatStringsSep " " cfg.ensureDatabases}; do
                  psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 || \
                    psql -d postgres -tAc "CREATE DATABASE \"$db\""
                done
              '';
            in
            "+${script}";

          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";

          KillSignal = "SIGINT";
          KillMode = "mixed";
          TimeoutSec = 60;

          # Hardening
          ReadWritePaths = [ cfg.dataDir ];
          DevicePolicy = "closed";
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          MemoryDenyWriteExecute = true;
          NoNewPrivileges = true;
          ProcSubset = "pid";
          ProtectProc = "invisible";
          RemoveIPC = true;
          RestrictAddressFamilies = [
            # "AF_INET"
            # "AF_INET6"
            # "AF_NETLINK"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
        };
      };

      sockets.postgres = {
        Unit = {
          Description = "PostgreSQL public socket";
        };
        Socket = {
          ListenStream = "%t/.s.PGSQL.5432";
          SocketMode = "0700";
          # Active this service on initial socket connection
          Service = "proxy-to-postgres.service";
        };
        Install = {
          WantedBy = [ "sockets.target" ];
        };
      };

      services.proxy-to-postgres = {
        Unit = {
          Description = "PostgreSQL socket proxy";
          Requires = [ "postgres.service" ];
          After = [ "postgres.service" ];
          JoinsNamespaceOf = [ "postgres.service" ];
        };
        Service = {
          Type = "notify";
          ExecStart = builtins.concatStringsSep " " [
            "${pkgs.systemdMinimal}/lib/systemd/systemd-socket-proxyd"
            "--exit-idle-time=600"
            "%t/postgres/.s.PGSQL.5432"
          ];
          PrivateTmp = true;
        };
      };
    };
  };
}
