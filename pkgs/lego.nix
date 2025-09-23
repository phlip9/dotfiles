{
  fetchFromGitHub,
  lego,
}:
# Patched Let's Encrypt ACME client for issuing webpki TLS certs
# * feat: support --private-key with a PKCS#8 keypair
# Awaiting 4.26.0+ release in nixpkgs
lego.overrideAttrs (old: {
  version = "v4.26.0+2655";
  src = fetchFromGitHub {
    owner = "go-acme";
    repo = "lego";
    rev = "26920e75f7fc5cc49a217fd58329847bed6d5788";
    hash = "sha256-awF+nqTfXmpD4AkG0roQfYJuXhDLdc1pPiz+fPhTOZc=";
  };
  vendorHash = "sha256-BdOS4BNWtonLoZO4YA85VdB6MRbMqoO8MGb4XNEwfCk=";
})
