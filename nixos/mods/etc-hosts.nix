{
  config,
  pkgs,
  lib,
  ...
}:

{
  options.phlip9.networking.resolveFqdnToLocalhost = lib.mkEnableOption ''
    Configure the local machine DNS so we can conveniently send requests to
    other services on the same machine with the real DNS name and real
    certs, while still just using local loopback networking.

    ```
    # /etc/hosts
    ::1 localhost phlipnixos phlipnixos.lan
    127.0.0.1 localhost phlipnixos phlipnixos.lan
    ```

    Unlike stock NixOS, this supports resolving the hostname/FQDN to IPv6 `::1`
    and IPv4 `127.0.0.1`, instead of just `127.0.0.2` for the hostname/FQDN.
  '';

  config.networking = lib.mkIf config.phlip9.networking.resolveFqdnToLocalhost {
    hostFiles =
      let
        hostName = config.networking.hostName;
        fqdn = config.networking.fqdn or "";

        hostNames = lib.unique (
          builtins.filter (s: builtins.stringLength s > 0) ([
            "localhost"
            hostName
            fqdn
          ])
        );
        hostNamesStr = builtins.concatStringsSep " " hostNames;

        hostsFile = pkgs.writeText "hosts" ''
          ::1 ${hostNamesStr}
          127.0.0.1 ${hostNamesStr}
        '';
      in
      lib.mkForce [ hostsFile ];
  };
}
