# modules/packages.nix
#
# Declarative package intent for nixpods consumers.
#
# nixpods itself declares no packages -- it is a build-time Quadlet translator, not an installer
# (see the repo README's "Boundaries"). But `podman-compose` is host tooling a podman workflow
# reaches for constantly -- a `compose.yml` this repo does not model, ad-hoc runs outside a
# quadlet unit -- and the operator has ruled that it belongs declared alongside the plane that
# actually uses it, rather than hand-installed per host. This module is that one narrow exception:
# it does not become a general package manager, and it names nothing beyond the one tool below.
#
# Same shape as nixiam's own modules/packages.nix: a flat baseline, backend-mapped by the two
# sibling files next to this one.
{ config, lib, ... }:
let
  cfg = config.nixpods.packages;
in
{
  options.nixpods.packages = {
    # Baseline package names before backend mapping.
    baseline = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "podman-compose" ];
      defaultText = lib.literalExpression ''[ "podman-compose" ]'';
      description = ''
        Baseline packages this module declares for all nixpods consumers, before a backend maps
        them to its concrete package source format.
      '';
    };

    # Platform-mapped outputs consumed by backends.
    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Baseline pacman package names. This keeps the public face of the policy one list while
        each backend maps to its own package source.
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Baseline AUR package names. Left empty for this policy today because `podman-compose` has
        an official pacman name (verified against the Arch `extra` repository).
      '';
    };

    nixosPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        NixOS package attribute names (as seen by nixpkgs). The baseline keeps these equal to
        `nixpods.packages.baseline` for now.
      '';
    };
  };

  config.nixpods.packages = {
    archPackages = lib.unique cfg.baseline;
    aurPackages = [ ];
    nixosPackages = lib.unique cfg.baseline;
  };
}
