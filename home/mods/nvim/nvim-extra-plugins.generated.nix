# GENERATED by ./pkgs/applications/editors/vim/plugins/update.py. Do not edit!
{
  lib,
  buildVimPlugin,
  buildNeovimPlugin,
  fetchFromGitHub,
  fetchgit,
}: final: prev: {
  kanagawa-nvim = buildVimPlugin {
    pname = "kanagawa.nvim";
    version = "2024-02-12";
    src = fetchFromGitHub {
      owner = "rebelot";
      repo = "kanagawa.nvim";
      rev = "ab41956c4559c3eb21e713fcdf54cda1cb6d5f40";
      sha256 = "0gii4kfp8hpr9413pq28fd2b77yrhcfl3476ndgydzclnibw9yj7";
    };
    meta.homepage = "https://github.com/rebelot/kanagawa.nvim/";
  };
}