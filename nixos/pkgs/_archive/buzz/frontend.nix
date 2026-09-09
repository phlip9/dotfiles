{
  stdenvNoCC,
  fetchPnpmDeps,
  nodejs,
  pnpmConfigHook,

  pnpm,
  src,
  version,
}:

stdenvNoCC.mkDerivation {
  pname = "buzz-frontend";
  inherit src version;

  pnpmDeps = fetchPnpmDeps {
    pname = "buzz";
    inherit
      pnpm
      src
      version
      ;
    fetcherVersion = 4;
    hash = "sha256-Tboy+MG/VvdxUpJw7Xv0oubK58MIpvChvbU30uO4M4A=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
  ];

  env.COREPACK_ENABLE_STRICT = 0;

  buildPhase = ''
    runHook preBuild

    pnpm --dir desktop build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R desktop/dist/. "$out/"

    runHook postInstall
  '';
}
