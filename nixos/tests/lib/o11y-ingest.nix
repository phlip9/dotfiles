# Fixtures for tests of the o11y ingest endpoint
# (nixos/mods/o11y/server/ingest.nix) + remote collectors.
#
# Usage: `ingestLib = import ./lib/o11y-ingest.nix { inherit pkgs; };`
{ pkgs }:

let
  inherit (pkgs) lib;
  withOpenssl = {
    nativeBuildInputs = [ pkgs.openssl ];
  };
in
{
  # Self-signed TLS cert (`cert.pem`) + key (`key.pem`) for `domain`. The
  # cert is its own CA: clients trust it w/ `security.pki.certificateFiles`.
  # Test-only: the key is in the store.
  tlsCert =
    domain:
    pkgs.runCommand "o11y-test-tls-${domain}" withOpenssl ''
      mkdir $out
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
        -days 3650 -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain}" \
        -keyout $out/key.pem -out $out/cert.pem 2> /dev/null
    '';

  # htpasswd file w/ one line per `{ <username> = <password>; }`, hashed
  # w/ the recipe in `server.ingest.htpasswdFile`'s description.
  htpasswd =
    users:
    pkgs.runCommand "o11y-test-htpasswd" withOpenssl ''
      entry() {
        printf '%s\n' "$2" > password
        echo "$1:$(openssl passwd -6 -stdin < password)"
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (user: pw: ''
          entry ${lib.escapeShellArg user} ${lib.escapeShellArg pw} >> $out
        '') users
      )}
    '';
}
