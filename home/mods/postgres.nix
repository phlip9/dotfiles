{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) literalExpression mkOption optionalString types;

  cfg = config.services.postgres;
  pkg = cfg.package;

  postgresqlConf = pkgs.writeTextDir "postgresql.conf" ''
    # Only allow connections via unix socket
    listen_addresses = '''
    unix_socket_permissions = 0700

    ssl = off
  '';
  pgHbaConf = pkgs.writeTextDir "pg_hba.conf" ''
    # Type  DB   User          Addr       Method

    # Only local connections
    local   all  ${config.home.username}  peer
    local   all  all                      reject
  '';
in {
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
        default = [];
        description = ''
          Ensures that the specified databases exist.
          This option will never delete existing databases, especially not when the value of this
          option is changed. This means that databases created once through this option or
          otherwise have to be removed manually.
        '';
        example = ["gitea" "nextcloud"];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # include postgres bins in $PATH
    home.packages = [pkg];

    systemd.user.services.postgres = {
      Unit = {
        Description = "PostgreSQL v${pkg.version} DB server";
        # Stop when `proxy-to-postgres.service` stops due to inactivity
        StopWhenUnneeded = true;
      };

      Service = {
        Type = "notify";

        Environment = [
          "PATH=${lib.makeBinPath [pkg pkgs.coreutils pkgs.gnugrep]}"
          "PGDATA=${cfg.dataDir}"
          "PGHOST=%t/postgres"
        ];

        ExecStartPre = let
          script = pkgs.writeShellScript "postgres-pre-start" ''
            set -euxo pipefail

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
        in "+${script}";

        ExecStart = "${pkg}/bin/postgres --unix_socket_directories=%t/postgres";

        ExecStartPost = let
          script = pkgs.writeShellScript "postgres-post-start" ''
            set -euxo pipefail

            # wait for the postgres to be ready
            pg_isready -d template1 --timeout=15

            # run the initial script on first startup if set
            if [[ -e "$PGDATA/.first_startup" ]]; then
              ${optionalString (cfg.initialScript != null) "psql -d postgres -f \"${cfg.initialScript}\""}
              rm "$PGDATA/.first_startup"
            fi

            # ensure databases exist
            for db in ${lib.concatStringsSep " " cfg.ensureDatabases}; do
              psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 || \
                psql -d postgres -tAc "CREATE DATABASE \"$db\""
            done
          '';
        in "+${script}";

        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";

        KillSignal = "SIGINT";
        KillMode = "mixed";
        TimeoutSec = 60;

        # Hardening
        ReadWritePaths = [cfg.dataDir];
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

    systemd.user.sockets.postgres = {
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
        WantedBy = ["sockets.target"];
      };
    };

    systemd.user.services.proxy-to-postgres = {
      Unit = {
        Description = "PostgreSQL socket proxy";
        Requires = ["postgres.service"];
        After = ["postgres.service"];
        JoinsNamespaceOf = ["postgres.service"];
      };
      Service = {
        Type = "notify";
        ExecStart = builtins.concatStringsSep " " [
          "${pkgs.systemdMinimal}/lib/systemd/systemd-socket-proxyd"
          "--exit-idle-time=30"
          "%t/postgres/.s.PGSQL.5432"
        ];
        PrivateTmp = true;
      };
    };
  };
}
