# Bubblewrap sandbox wrapper for marinara-engine.
#
# Restricts filesystem access to just /nix/store (read-only) and a
# single writable data directory. Network access is allowed since the
# server must listen for HTTP clients and call remote AI APIs.
#
# Runtime data (SQLite db, uploads, etc.) lives in:
#   $MARINARA_DATA_DIR  (default: $XDG_DATA_HOME/marinara-engine)
{
  lib,
  writeShellApplication,
  bubblewrap,
  marinara-engine-unwrapped,
}:
writeShellApplication {
  name = "marinara-engine";
  runtimeInputs = [ bubblewrap ];

  text = ''
    data_dir="''${MARINARA_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/marinara-engine}"
    mkdir -p "$data_dir"

    HOST="''${HOST:-localhost}"
    PORT="''${PORT:-7860}"

    echo ""
    echo "--- MARINARA ENGINE ---"
    echo ""
    echo "    http://$HOST:$PORT/"
    echo ""

    exec bwrap \
      --ro-bind /nix/store /nix/store \
      --proc /proc \
      --dev /dev \
      --tmpfs /tmp \
      --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
      --ro-bind-try /etc/hosts /etc/hosts \
      --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
      --ro-bind-try /etc/ssl /etc/ssl \
      --ro-bind-try /etc/static/ssl /etc/static/ssl \
      --bind "$data_dir" "$data_dir" \
      --unshare-all \
      --share-net \
      --new-session \
      --die-with-parent \
      --setenv MARINARA_LITE true \
      --setenv NODE_ENV production \
      --setenv DATA_DIR "$data_dir" \
      --setenv HOST "$HOST" \
      --setenv PORT "$PORT" \
      --setenv LOG_LEVEL "''${LOG_LEVEL:-warn}" \
      -- \
      ${lib.getExe marinara-engine-unwrapped} "$@"
  '';

  meta = {
    homepage = "https://github.com/Pasta-Devs/Marinara-Engine";
    license = lib.licenses.agpl3Only;
    mainProgram = "marinara-engine";
    platforms = lib.platforms.linux;
  };
}
