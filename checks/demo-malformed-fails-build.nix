# checks/demo-malformed-fails-build.nix
#
# THE REPO'S THESIS, made buildable on purpose so it can be watched failing. Not part of
# `checks/default.nix`'s own output set: `nix flake check` requires every `checks.<system>.*`
# derivation to actually BUILD successfully (see `nix flake check --help`'s "the derivations
# specified by the flake's checks output can be built successfully"), so a derivation that is
# SUPPOSED to fail cannot live there without making the whole flake check red for the wrong
# reason. `packages.<system>.*` outputs, by contrast, are only required to EVALUATE as valid
# derivations -- nix never attempts to build them as part of `nix flake check` -- which is
# exactly the asymmetry this file needs: reachable, inspectable, and buildable on demand
# (`nix build .#demo-malformed-container-fails-build`), while leaving `nix flake check` itself
# green.
#
# The malformed input below (`ThisKeyDoesNotExist=...`, inside an otherwise normal `[Container]`
# block) is not invented for effect -- it is one of the exact shapes this repo verified,
# empirically, against the real podman quadlet generator this session: an unrecognized key makes
# the generator itself exit non-zero and emit NO `.service` file for that unit at all. Building
# this derivation reproduces that failure through the actual lib/build.nix mechanism nixpods
# ships, not a stand-in.
{ pkgs, lib, podman }:
let
  build = import ../lib/build.nix { inherit lib; };
in
build.mkQuadletUnitPackage {
  inherit pkgs podman;
  type = "system";
  name = "nixpods-demo-malformed-container-fails-build";
  objects = [
    {
      ref = "broken-demo.container";
      serviceName = "broken-demo";
      text = ''
        [Container]
        Image=docker.io/library/nginx@sha256:0000000000000000000000000000000000000000000000000000000000000000
        ThisKeyDoesNotExist=banana
      '';
    }
  ];
}
