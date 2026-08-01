{
  buzz,
  cacert,
  dbus,
  lib,
  makeFontsConf,
  mesa,
  procps,
  runCommand,
  weston,
}:

let
  fontsConf = makeFontsConf { fontDirectories = [ ]; };
in
runCommand "buzz-headless-test"
  {
    nativeBuildInputs = [
      dbus
      mesa.llvmpipeHook
      procps
      weston
    ];
    meta.platforms = [ "x86_64-linux" ];
  }
  ''
    buzzTestRoot="$TMPDIR/buzz-headless"
    buzzTestHome="$buzzTestRoot/home"
    buzzRuntimeDir="$buzzTestRoot/runtime"
    buzzDataDir="$buzzTestRoot/data"
    buzzLog="$buzzTestRoot/buzz.log"
    westonLog="$buzzTestRoot/weston.log"

    mkdir -p \
      "$buzzTestHome" \
      "$buzzTestRoot/cache" \
      "$buzzTestRoot/config" \
      "$buzzDataDir" \
      "$buzzTestRoot/state"
    mkdir -m700 "$buzzRuntimeDir"

    # Stop both process trees if a startup assertion fails early.
    cleanup() {
      set +e
      if test -n "''${buzzTestPid:-}" && \
        kill -0 "$buzzTestPid" 2>/dev/null; then
        kill "$buzzTestPid"
        wait "$buzzTestPid"
      fi
      if test -n "''${westonPid:-}" && \
        kill -0 "$westonPid" 2>/dev/null; then
        kill "$westonPid"
        wait "$westonPid"
      fi
    }
    trap cleanup EXIT

    XDG_RUNTIME_DIR="$buzzRuntimeDir" \
      ${lib.getExe weston} \
        --backend=headless \
        --renderer=pixman \
        --shell=kiosk \
        --socket=wayland-buzz \
        --fake-seat \
        --idle-time=0 \
        --width=1280 \
        --height=720 \
        --no-config \
        --log="$westonLog" &
    westonPid=$!

    # Wait for the compositor before starting GTK and WebKit.
    for attempt in $(seq 1 50); do
      test -S "$buzzRuntimeDir/wayland-buzz" && break
      kill -0 "$westonPid"
      sleep 0.1
    done
    test -S "$buzzRuntimeDir/wayland-buzz"

    timeout --foreground --kill-after=3s 15s \
      ${dbus}/bin/dbus-run-session \
        --config-file=${dbus}/share/dbus-1/session.conf -- \
      env \
        HOME="$buzzTestHome" \
        XDG_RUNTIME_DIR="$buzzRuntimeDir" \
        XDG_CONFIG_HOME="$buzzTestRoot/config" \
        XDG_CACHE_HOME="$buzzTestRoot/cache" \
        XDG_DATA_HOME="$buzzDataDir" \
        XDG_STATE_HOME="$buzzTestRoot/state" \
        FONTCONFIG_FILE=${fontsConf} \
        SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt \
        GDK_BACKEND=wayland \
        WAYLAND_DISPLAY=wayland-buzz \
        HTTP_PROXY=http://127.0.0.1:9 \
        HTTPS_PROXY=http://127.0.0.1:9 \
        NO_PROXY=localhost,127.0.0.1 \
        ${lib.getExe buzz} --safe-rendering \
      >"$buzzLog" 2>&1 &
    buzzTestPid=$!

    # WebKit local storage proves the embedded frontend loaded. Keep the
    # renderer alive long enough to exercise its media initialization too.
    webkitPid=""
    localStorage=""
    for attempt in $(seq 1 100); do
      dbusSessionPid="$(
        pgrep -P "$buzzTestPid" | head -n1 || true
      )"
      buzzPid=""
      if test -n "$dbusSessionPid"; then
        buzzPid="$(
          pgrep -P "$dbusSessionPid" -f '${lib.getExe buzz}' | \
            head -n1 || true
        )"
      fi
      if test -n "$buzzPid"; then
        webkitPid="$(
          pgrep -P "$buzzPid" -f '/WebKitWebProcess ' | head -n1 || true
        )"
      fi
      localStorage="$(
        find "$buzzDataDir" \
          -path '*/localstorage/tauri_localhost_0.localstorage' \
          -print -quit 2>/dev/null || true
      )"
      test -n "$webkitPid" && test -n "$localStorage" && break
      if ! kill -0 "$buzzTestPid"; then
        cat "$buzzLog"
        cat "$westonLog"
        exit 1
      fi
      sleep 0.1
    done
    test -n "$webkitPid"
    test -n "$localStorage"

    sleep 3
    if ! kill -0 "$buzzPid" || ! kill -0 "$webkitPid"; then
      cat "$buzzLog"
      cat "$westonLog"
      exit 1
    fi

    set +e
    wait "$buzzTestPid"
    buzzStatus=$?
    set -e
    buzzTestPid=""
    test "$buzzStatus" -eq 124

    kill "$westonPid"
    wait "$westonPid" || true
    westonPid=""

    # Fail on errors which leave the parent process and splash window alive.
    fatalPattern='Could not connect to localhost'
    fatalPattern+='|GStreamer element .* not found'
    fatalPattern+='|GStreamer-CRITICAL'
    fatalPattern+='|(Gdk|GLib-GObject)-CRITICAL'
    fatalPattern+='|Could not create (default|surfaceless) EGL display'
    fatalPattern+='|Aborting|panicked at'
    if grep -Eq "$fatalPattern" "$buzzLog"; then
      cat "$buzzLog"
      exit 1
    fi

    grep -Fq 'media proxy listening on 127.0.0.1:' "$buzzLog"
    grep -Fq 'repos dir resolved at boot' "$buzzLog"
    touch "$out"
  ''
