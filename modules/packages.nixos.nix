# NixOS backend for nixpods baseline packages.
#
# Unlike the Arch-backed system-manager plane, nixpkgs package installation is part of the same
# evaluation and can be done directly from this module.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixpods.packages;

  # NOT `builtins.tryEval (lib.getAttrFromPath ...)` -- checked directly against this Nix
  # (Determinate Nix 2.34.8): `lib.getAttrFromPath`'s own "not found" branch is
  # `abort "cannot find attribute ..."`, and `abort` is NOT catchable by `tryEval` at any nesting
  # level (confirmed empirically: `builtins.tryEval (abort "x")` itself throws past the tryEval,
  # unlike `builtins.tryEval (throw "x")`, which returns `{ success = false; }` as expected). That
  # combination would hard-abort the entire evaluation the moment one baseline entry does not
  # resolve, taking `nix flake check` down with it rather than failing this one assertion by name
  # -- exactly the silent-turned-catastrophic failure this module exists to avoid. So existence is
  # tested with `hasAttrByPath` first (a `?`-style presence check that never forces or aborts on a
  # missing key), and `getAttrFromPath` is only ever called on a path already known to exist.
  path = pkgName: lib.splitString "." pkgName;
  evals = map
    (pkgName: { inherit pkgName; found = lib.hasAttrByPath (path pkgName) pkgs; })
    cfg.nixosPackages;

  installable = map (entry: lib.getAttrFromPath (path entry.pkgName) pkgs) (lib.filter (entry: entry.found) evals);
  unavailable = map (entry: entry.pkgName) (lib.filter (entry: !entry.found) evals);
in
{
  imports = [ ./packages.nix ];

  config = {
    environment.systemPackages = lib.unique installable;
    assertions = lib.optional (unavailable != [ ]) {
      assertion = false;
      message = ''
        nixpods: ${toString (builtins.length unavailable)} declared baseline package(s) do not resolve in this nixpkgs:
        ${lib.concatStringsSep ", " unavailable}
      '';
    };
  };
}
