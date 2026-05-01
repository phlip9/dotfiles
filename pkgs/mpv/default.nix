{
  symlinkJoin,
  mpv,
  mpvScripts,
}:

let
  mpvWithScripts = mpv.override {
    # mpv,
    # extraMakeWrapperArgs ? [ ],
    # extraUmpvWrapperArgs ? [ ],

    # for some reason this depends on deno, which is not cached (?) and takes
    # forever to build.
    youtubeSupport = false;

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
