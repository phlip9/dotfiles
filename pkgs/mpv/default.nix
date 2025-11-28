{ symlinkJoin, mpv }:

symlinkJoin {
  name = "mpv-with-patched-umpv-${mpv.unwrapped.version}";

  paths = [ mpv ];

  postBuild = ''
    ln -sf "${./umpv}" "$out/bin/umpv"
  '';

  meta.mainProgram = "mpv";
}
