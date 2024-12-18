{
  fetchFromGitHub,
  fetchYarnDeps,
  fixup-yarn-lock,
  nodejs_18,
  stdenvNoCC,
  yarn,
  lib,
}:
stdenvNoCC.mkDerivation rec {
  pname = "firefox-profiler";
  version = "2024.12.16";

  src = fetchFromGitHub {
    owner = "firefox-devtools";
    repo = "profiler";
    rev = "16dab1c5da59227a874a9ec2f2ae7f8347b67732";
    hash = "sha256-7DEbPAGJSy+Tn7Of5LTj42r0y4p4HCi5la6ja/yh1iI=";
  };

  nativeBuildInputs = [
    fixup-yarn-lock
    nodejs_18
    (yarn.override {nodejs = nodejs_18;})
  ];

  yarnOfflineCache = fetchYarnDeps {
    yarnLock = "${src}/yarn.lock";
    hash = "sha256-PuC+UKLcIICS4NZWPq+uFs96JRbl3mbnAFnkLRw4uoI=";
  };

  configurePhase = ''
    runHook preConfigure

    export HOME=$(mktemp -d)
    yarn config --offline set yarn-offline-mirror "$yarnOfflineCache"
    fixup-yarn-lock yarn.lock
    yarn install --frozen-lockfile --offline --no-progress --non-interactive
    patchShebangs node_modules/

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    yarn --offline build-prod
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mv dist $out
    runHook postInstall
  '';

  meta = {
    description = "Firefox Profiler - Web app for Firefox performance analysis";
    license = lib.licenses.mpl20;
  };
}
