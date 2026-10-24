# Extension module around rbitcoin's upstream NixOS module.
{
  lib,
  phlipPkgsNixos,
  ...
}:

{
  # Upstream defaults to its flake's static musl build. Use our glibc build
  # against nixos-unstable instead.
  services.rbitcoin.package = lib.mkDefault phlipPkgsNixos.rbitcoin;
}
