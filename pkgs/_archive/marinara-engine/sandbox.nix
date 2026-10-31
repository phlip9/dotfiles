# Bubblewrap sandbox wrapper for marinara-engine.
#
# Restricts filesystem access to just /nix/store (read-only) and a
# single writable data directory. Network access is allowed since the
# server must listen for HTTP clients and call remote AI APIs.
#
# Runtime data (SQLite db, uploads, etc.) lives in:
# - $MARINARA_DATA_DIR (default: $XDG_DATA_HOME/marinara-engine)
{
  bash,
  bubblewrap,
  cacert,
  coreutils,
  diffutils,
  findutils,
  gawk,
  git,
  glibc,
  gnugrep,
  gnused,
  lib,
  marinara-engine-unwrapped,
  pnpm,
  python3,
  ripgrep,
  which,
  writeShellApplication,
}:
writeShellApplication {
  name = "marinara-engine";
  runtimeInputs = [
    bubblewrap
    coreutils
  ];

  text = ''
    data_dir="''${MARINARA_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/marinara-engine}"
    case "$data_dir" in
      /*) ;;
      *)
        echo "MARINARA_DATA_DIR must be an absolute path" >&2
        exit 2
        ;;
    esac
    data_dir="$(realpath -m "$data_dir")"
    if [ "$data_dir" = / ]; then
      echo "MARINARA_DATA_DIR must not be /" >&2
      exit 2
    fi

    mkdir -p "$data_dir" \
      "$data_dir/storage" \
      "$data_dir/claude-config" \
      "$data_dir/tmp"

    # Mari only ever dials 127.0.0.1, so we use that here unstead of localhost
    HOST="''${HOST:-127.0.0.1}"
    PORT="''${PORT:-7860}"

    # Internal tool URL must stay on loopback even if HOST is 0.0.0.0 / LAN IP.
    # Allow explicit override, but default to IPv4 loopback to match mari.js.
    MARI_SERVER_URL="''${MARI_SERVER_URL:-http://127.0.0.1:$PORT}"

    echo ""
    echo "--- MARINARA ENGINE ---"
    echo ""
    echo "    http://$HOST:$PORT/"
    echo "    data: $data_dir"
    echo "    mari: $MARI_SERVER_URL"
    echo ""

    # Build bwrap argv. --clearenv first, then re-export only what we need.
    # This prevents host PATH/NODE_OPTIONS/API keys/etc from leaking in unless
    # they live in $data_dir/.env (MARINARA_ENV_FILE) by design.
    # --dev creates bubblewrap's minimal device filesystem, not a host /dev bind.
    # Use fixed sandbox paths for host state and the Nix CA bundle.
    exec bwrap \
      --unshare-all \
      --share-net \
      --new-session \
      --die-with-parent \
      --cap-drop ALL \
      --clearenv \
      --hostname marinara \
      --chdir /data \
      \
      --ro-bind /nix/store /nix/store \
      --proc /proc \
      --dev /dev \
      --tmpfs /tmp \
      --tmpfs /run \
      --dir /var \
      --dir /lib64 \
      --symlink ${glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 \
      --ro-bind-try /etc/passwd /etc/passwd \
      --ro-bind-try /etc/group /etc/group \
      --ro-bind-try /etc/localtime /etc/localtime \
      --ro-bind-try /etc/zoneinfo /etc/zoneinfo \
      --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
      --ro-bind-try /etc/hosts /etc/hosts \
      --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
      --bind "$data_dir" /data \
      --setenv MARINARA_LITE true \
      --setenv NODE_ENV production \
      --setenv PATH ${
        lib.makeBinPath [
          bash
          coreutils
          diffutils
          findutils
          gawk
          git
          gnugrep
          gnused
          marinara-engine-unwrapped
          marinara-engine-unwrapped.nodejs
          pnpm
          python3
          ripgrep
          which
        ]
      } \
      --setenv HOME /data \
      --setenv DATA_DIR /data \
      --setenv FILE_STORAGE_DIR /data/storage \
      --setenv CLAUDE_CONFIG_DIR /data/claude-config \
      --setenv MARINARA_ENV_FILE /data/.env \
      --setenv TMPDIR /data/tmp \
      --setenv HOST "$HOST" \
      --setenv PORT "$PORT" \
      --setenv MARI_SERVER_URL "$MARI_SERVER_URL" \
      --setenv LOG_LEVEL "''${LOG_LEVEL:-warn}" \
      --setenv SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
      --setenv NIX_SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
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
