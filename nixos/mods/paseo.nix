# Extension module around Paseo's upstream NixOS daemon module.
{
  config,
  lib,
  pkgs,
  phlipPkgs,
  phlipPkgsNixos,
  ...
}:

let
  cfg = config.services.paseo;

  isIpv6Addr = addr: lib.hasInfix ":" addr && !(lib.hasPrefix "[" addr);
  formatHost = addr: if isIpv6Addr addr then "[${addr}]" else addr;
  hostPort = addr: port: "${formatHost addr}:${toString port}";

  daemonListen = hostPort cfg.listenAddress cfg.port;
  serviceProxyListen = hostPort cfg.serviceProxy.listenAddress cfg.serviceProxy.port;
  relayListen = hostPort cfg.relayServer.listenAddress cfg.relayServer.port;

  nginxVhostConfig = ''
    client_max_body_size ${cfg.nginx.clientMaxBodySize};
  '';

  longLivedProxyConfig = ''
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  '';
in
{
  options.services.paseo = {
    auth.passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File containing the plaintext daemon password.

        This should point at a runtime secret file, usually
        config.sops.secrets.<name>.path. The service reads it through systemd
        LoadCredential and passes only the credential path to the daemon.
      '';
    };

    relay.publicEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Relay endpoint advertised to clients, as host:port.";
    };

    webUi = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Serve the bundled browser UI from the daemon.";
      };

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public HTTPS domain for the daemon web UI.";
      };

      publicBaseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if cfg.webUi.domain == null then null else "https://${cfg.webUi.domain}";
        description = "Public app base URL advertised to clients.";
      };
    };

    relayServer = {
      enable = lib.mkEnableOption "self-hosted paseo-relay service";

      package = lib.mkOption {
        type = lib.types.package;
        default = phlipPkgsNixos.paseo-relay;
        description = "paseo-relay package.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "::1";
        description = "Relay service listen address.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8411;
        description = "Relay service listen port.";
      };

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public HTTPS domain proxied to the relay service.";
      };
    };

    serviceProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Paseo's optional service-only proxy listener.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "::1";
        description = "Service proxy listen address.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 6768;
        description = "Service proxy listen port.";
      };

      publicBaseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Public base URL for generated workspace service links.

          Paseo currently generates links as per-service subdomains under this
          host, so public exposure requires wildcard DNS and TLS for the base
          host. Leave unset when wildcard certificates are not available.
        '';
      };

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public nginx vhost domain proxied to the service listener.";
      };
    };

    nginx = {
      forceSSL = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Force HTTPS for generated nginx virtual hosts.";
      };

      enableACME = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable ACME for generated nginx virtual hosts.";
      };

      clientMaxBodySize = lib.mkOption {
        type = lib.types.str;
        default = "100m";
        description = "nginx client_max_body_size for Paseo vhosts.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.auth.passwordFile != null;
        message = "services.paseo.auth.passwordFile must be set.";
      }
      {
        assertion = cfg.serviceProxy.domain == null || cfg.serviceProxy.enable;
        message = "services.paseo.serviceProxy.domain requires serviceProxy.enable.";
      }
    ];

    services.paseo = {
      listenAddress = lib.mkDefault "::1";
      package = lib.mkDefault phlipPkgs.paseo;
    };

    systemd.services.paseo = {
      path = [
        pkgs.bashInteractive
        pkgs.coreutils
        pkgs.git
        pkgs.openssh
      ];

      environment = {
        PASEO_PASSWORD_FILE = "%d/daemon-password";
        PASEO_WEB_UI_ENABLED = if cfg.webUi.enable then "true" else "false";
      }
      // lib.optionalAttrs (cfg.webUi.publicBaseUrl != null) {
        PASEO_APP_BASE_URL = cfg.webUi.publicBaseUrl;
        PASEO_CORS_ORIGINS = cfg.webUi.publicBaseUrl;
      }
      // lib.optionalAttrs (cfg.relay.publicEndpoint != null) {
        PASEO_RELAY_PUBLIC_ENDPOINT = cfg.relay.publicEndpoint;
      }
      // lib.optionalAttrs cfg.serviceProxy.enable {
        PASEO_SERVICE_PROXY_LISTEN = serviceProxyListen;
      }
      // lib.optionalAttrs (cfg.serviceProxy.publicBaseUrl != null) {
        PASEO_SERVICE_PROXY_PUBLIC_BASE_URL = cfg.serviceProxy.publicBaseUrl;
      };

      serviceConfig = {
        ExecStart =
          let
            daemonCommand =
              "${cfg.package}/bin/paseo-server"
              + lib.optionalString (!cfg.relay.enable) " --no-relay";
          in
          lib.mkForce (
            "${pkgs.bashInteractive}/bin/bash -lc ${lib.escapeShellArg "exec ${daemonCommand}"}"
          );
        LoadCredential = lib.mkIf (cfg.auth.passwordFile != null) [
          "daemon-password:${cfg.auth.passwordFile}"
        ];
        WorkingDirectory = lib.mkForce (
          if cfg.user == "paseo" then cfg.dataDir else "/home/${cfg.user}"
        );
      };
    };

    systemd.services.paseo-relay = lib.mkIf cfg.relayServer.enable {
      description = "Paseo self-hosted relay";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${cfg.relayServer.package}/bin/paseo-relay --addr ${relayListen} --log-format json";
        Restart = "on-failure";
        RestartSec = 5;
        LockPersonality = true;
        NoNewPrivileges = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictSUIDSGID = true;
      };
    };

    services.nginx =
      lib.mkIf
        (
          cfg.webUi.domain != null
          || cfg.relayServer.domain != null
          || cfg.serviceProxy.domain != null
        )
        {
          enable = true;
          recommendedProxySettings = lib.mkDefault true;

          virtualHosts =
            lib.optionalAttrs (cfg.webUi.domain != null) {
              ${cfg.webUi.domain} = {
                forceSSL = cfg.nginx.forceSSL;
                enableACME = cfg.nginx.enableACME;
                extraConfig = nginxVhostConfig;
                locations."/" = {
                  proxyPass = "http://${daemonListen}";
                  proxyWebsockets = true;
                  extraConfig = longLivedProxyConfig;
                };
              };
            }
            // lib.optionalAttrs (cfg.relayServer.domain != null) {
              ${cfg.relayServer.domain} = {
                forceSSL = cfg.nginx.forceSSL;
                enableACME = cfg.nginx.enableACME;
                extraConfig = nginxVhostConfig;
                locations = {
                  "/health".proxyPass = "http://${relayListen}";
                  "/ws" = {
                    proxyPass = "http://${relayListen}";
                    proxyWebsockets = true;
                    extraConfig = longLivedProxyConfig;
                  };
                };
              };
            }
            // lib.optionalAttrs (cfg.serviceProxy.domain != null) {
              ${cfg.serviceProxy.domain} = {
                forceSSL = cfg.nginx.forceSSL;
                enableACME = cfg.nginx.enableACME;
                extraConfig = nginxVhostConfig;
                locations."/" = {
                  proxyPass = "http://${serviceProxyListen}";
                  proxyWebsockets = true;
                  extraConfig = longLivedProxyConfig;
                };
              };
            };
        };
  };
}
