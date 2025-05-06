{
  fetchFromGitHub,
  openssl,
  pkg-config,
  rustPlatform,
}:
rustPlatform.buildRustPackage rec {
  pname = "imgen";
  version = "0.1.4";

  src = fetchFromGitHub {
    owner = "phlip9";
    repo = pname;
    tag = "v${version}";
    hash = "sha256-I7hVG3Gu/k05vo3Sg+foS1kF979OLrgHNqqZIUydDxM=";
  };

  cargoHash = "sha256-CZwoVyKGDwPMkq34jXIG6H5lG4al8g6kqno8gvl2hpA=";

  cargoBuildFlags = "-p imgen --bin imgen";

  nativeBuildInputs = [pkg-config];
  buildInputs = [openssl];
}
