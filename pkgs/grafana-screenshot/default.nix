# grafana-screenshot - drive the real Grafana UI w/ headless Firefox
# (playwright), for agents:
#
# - grafana-screenshot: PNG of a dashboard or panel, so agents can see the
#   dashboards they build.
#
# ex: grafana-screenshot scratch-nginx --from now-7d -o tmp/nginx.png
{
  dejavu_fonts,
  makeFontsConf,
  makeBinaryWrapper,
  playwright-driver,
  python3Packages,
  runCommand,
  writers,
}:
let
  # One script, w/ the command as its first arg.
  unwrapped = writers.writePython3Bin "grafana-browser" {
    libraries = [ python3Packages.playwright ];
    # We use the repo's 80-column limit.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./grafana-browser.py);

  # Only playwright's Firefox build.
  browsers = playwright-driver.browsers.override {
    withChromium = false;
    withChromiumHeadlessShell = false;
    withWebkit = false;
  };

  # Fallback for headless Linux hosts w/o a system fontconfig, where the
  # browser aborts or renders tofu. The script only uses it if the host has
  # no /etc/fonts (binary wrappers can't express the condition).
  fontsConf = makeFontsConf { fontDirectories = [ dejavu_fonts ]; };
in
runCommand "grafana-screenshot"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta.mainProgram = "grafana-screenshot";
  }
  ''
    # playwright's python + driver + browsers come from the same nixpkgs, so
    # their versions match.
    for command in screenshot; do
      makeWrapper ${unwrapped}/bin/grafana-browser \
        $out/bin/grafana-$command \
        --add-flags $command \
        --set PLAYWRIGHT_BROWSERS_PATH ${browsers} \
        --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true \
        --set GRAFANA_SCREENSHOT_FONTCONFIG_FILE ${fontsConf}
    done
  ''
