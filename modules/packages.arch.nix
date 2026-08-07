# system-manager backend for nixpods baseline packages.
#
# On Arch/CachyOS the package backend runs through nixarch's reconcile machinery: publish
# pacman/AUR lists and let nixarch own the reconcile transaction. Same shape as nixiam's own
# modules/packages.arch.nix.
{ config, ... }:
{
  imports = [ ./packages.nix ];

  config = {
    nixarch.packages.pacman = config.nixpods.packages.archPackages;
    nixarch.packages.aur = config.nixpods.packages.aurPackages;
  };
}
