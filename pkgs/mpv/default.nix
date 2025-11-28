{
  symlinkJoin,
  mpv,
  mpvScripts,
}:

let
  mpvWithScripts = mpv.override {
    # mpv,
    # extraMakeWrapperArgs ? [ ],
    # youtubeSupport ? true,
    # extraUmpvWrapperArgs ? [ ],
    scripts = [
      # nicer UI
      mpvScripts.uosc
    ];
  };
in

symlinkJoin {
  name = "mpv-with-patched-umpv-${mpvWithScripts.unwrapped.version}";

  paths = [ mpvWithScripts ];

  postBuild = ''
    ln -sf "${./umpv}" "$out/bin/umpv"
  '';

  meta.mainProgram = "mpv";
}
