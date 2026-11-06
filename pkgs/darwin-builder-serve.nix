# temporarily serve e.g. phliptop-mbp as a darwin-builder for sauna.
#
# See: <../doc/DARWIN-BUILDER.md>
{
  lib,
  autossh,
  coreutils,
  openssh,
  stdenv,
  writeShellApplication,
  writeText,
  nixDaemon ? "/nix/var/nix/profiles/default/bin/nix-daemon",
}:
let
  # sauna's client pubkey that phliptop-mbp trusts
  authorizedKeys = writeText "darwin-builder-authorized-keys" ''
    restrict,from="127.0.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINjK6VIf7EQXQ030LeuL+9i06KsMidyl66WEF0QotYId sauna-to-phliptop-mbp-builder
  '';

  # use a purpose built sshd config
  sshdConfig = writeText "darwin-builder-sshd-config" ''
    ListenAddress 127.0.0.1
    Port 22024
    AuthorizedKeysFile none
    AllowUsers phlip9
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    DisableForwarding yes
    PermitTTY no
    PermitUserRC no
    PidFile none
    ForceCommand ${nixDaemon} --stdio
    ${lib.optionalString stdenv.hostPlatform.isLinux "UsePAM no"}
  '';

  # caffeinate + autossh: make laptop stay awake while lid is closed, autossh
  # keeps ssh connected
  caffeinatedAutossh =
    lib.optionalString stdenv.hostPlatform.isDarwin "/usr/bin/caffeinate -s "
    + lib.getExe autossh;
in
writeShellApplication {
  name = "darwin-builder-serve";
  runtimeInputs = [ coreutils ];
  meta = {
    description = "Serve a temporary Nix builder to sauna over SSH";
    mainProgram = "darwin-builder-serve";
    platforms = lib.platforms.unix;
  };
  text = ''
    if (( EUID == 0 )); then
      echo 'Run darwin-builder-serve as phlip9, without sudo.' >&2
      exit 1
    fi
    if [[ ! -x ${lib.escapeShellArg nixDaemon} ]]; then
      echo 'Nix daemon executable is missing: ${nixDaemon}' >&2
      exit 1
    fi

    # keep the host identity stable across sessions, outside the Nix store.
    umask 077
    state_dir="$HOME/.ssh/darwin-builder"
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    host_key="$state_dir/host_ed25519"
    if [[ ! -f "$host_key" ]]; then
      ${lib.getExe' openssh "ssh-keygen"} -q -t ed25519 -N "" \
        -C "$(uname -n | cut -d. -f1)-builder-host" -f "$host_key"
    fi

    # StrictModes rejects the group-writable Nix store in the key's ancestry.
    install -m 600 ${authorizedKeys} "$state_dir/authorized_keys"
    sshd_options=(
      -f ${sshdConfig} -h "$host_key"
      -o "AuthorizedKeysFile=$state_dir/authorized_keys"
    )
    ${lib.getExe' openssh "sshd"} -t "''${sshd_options[@]}"

    printf 'Builder host public key (pin on sauna):\n'
    ${lib.getExe' openssh "ssh-keygen"} -y -f "$host_key"
    printf '\nStarting builder via sauna. Ctrl+C stops serving.\n'

    # own both children. if either child exits, tear down the entire session.
    children=()
    cleanup() {
      trap - EXIT
      trap "" INT TERM
      for child_pid in "''${children[@]}"; do
        kill "$child_pid" 2>/dev/null || true
      done
      for child_pid in "''${children[@]}"; do
        wait "$child_pid" 2>/dev/null || true
      done
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ${lib.getExe' openssh "sshd"} -D -e "''${sshd_options[@]}" &
    children+=("$!")
    # Reconnect the tunnel after sauna restarts or network drops. autossh
    # exits instead if the first attempt fails within 30s (AUTOSSH_GATETIME),
    # so auth/config errors don't loop. Retry backoff is capped at 30s.
    # `-M 0`: detect dead connections w/ ssh keepalives only.
    # Sauna port 22023 must match nixos/mods/darwin-builder.nix.
    AUTOSSH_PATH=${lib.getExe openssh} AUTOSSH_POLL=30 \
      AUTOSSH_LOGFILE=/dev/stderr \
      ${caffeinatedAutossh} -M 0 -NT \
        -S none -oControlMaster=no -oControlPersist=no \
        -oExitOnForwardFailure=yes -oConnectTimeout=5 \
        -oServerAliveInterval=5 -oServerAliveCountMax=2 \
        -R 127.0.0.1:22023:127.0.0.1:22024 sauna &
    children+=("$!")
    wait -n "''${children[@]}"
  '';
}
