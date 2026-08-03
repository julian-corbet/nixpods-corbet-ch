# modules/nixos.nix
#
# The NixOS plane. `modules/nixpods.nix` next to this file already did everything that is true on
# every plane -- rendered the Quadlet text, ran the real generator at build time, installed the
# rootful units through `systemd.packages` and their `wantedBy` drop-ins through
# `systemd.services`. This file adds only what does not exist anywhere else:
#
#   1. podman itself, via `virtualisation.podman.*` -- a NixOS-only module namespace, and the
#      reason a foreign-distro host needs `nixpods.podman.path` instead;
#   2. the ROOTLESS half, which needs a systemd `--user` tree. NixOS has one; system-manager does
#      not, which is why this lives here rather than in the shared file.
{ lib, config, ... }:

let
  cfg = config.nixpods;
in
{
  imports = [ ./nixpods.nix ];

  config = lib.mkMerge [
    {
      # Generate with the same podman this host actually runs. `mkDefault` rather than a plain
      # assignment so a host can still pin the generator independently -- but by default the
      # binary that writes the `ExecStart=` line and the binary named in it are one package,
      # which is what makes `nixpods.podman.path` unnecessary on this plane.
      #
      # UNCONDITIONAL, deliberately: gate this on "is anything declared" and the module system
      # deadlocks -- answering that question means building the units, building them reads this
      # option, and reading it re-asks the question. Setting it always costs nothing on a host
      # that declares no containers.
      nixpods.podman.package = lib.mkDefault config.virtualisation.podman.package;
    }

    (lib.mkIf (cfg.build.systemUnits != null || cfg.build.userUnits != null) {
      virtualisation.podman.enable = lib.mkDefault true;
    })

    (lib.mkIf (cfg.build.userUnits != null) {
      # `systemd.packages` is the ONE list that feeds units to BOTH manager instances on NixOS:
      # `nixos/lib/systemd-lib.nix`'s `generateUnits` defaults its `packages` argument to that
      # same list whether it is scanning a package's `lib/systemd/system/` (root) or
      # `lib/systemd/user/` (a `--user` manager). See lib/options.nix's rootlessOption for the
      # full reasoning, including why nixpods never depends on the user GENERATOR running.
      systemd.packages = [ cfg.build.userUnits ];
      systemd.user.services = cfg.build.userOverrides;

      # THE ROOTLESS LINGER REMINDER: nixpods never manages user accounts (out of scope, the same
      # boundary nixvm draws around bridges it never creates) but a lingering-less uid's --user
      # manager does not exist unprompted at boot, so a unit installed there silently never
      # starts -- exactly the "undiagnosable until later" failure this whole repo exists to
      # avoid. Best-effort: warn by object name whenever the uid does not resolve to a
      # `users.users.*` entry with `linger = true` in THIS config; says nothing about lingering
      # managed imperatively (`loginctl enable-linger`) outside NixOS, which this cannot see and
      # does not warn about.
      warnings = lib.mapAttrsToList
        (serviceName: uid: ''
          nixpods: ${serviceName} installs into uid ${toString uid}'s systemd --user
          manager (rootless.uid is set), but no users.users.<name> entry in this config has that
          uid with linger = true. Without lingering, that uid's --user manager does not exist
          until someone actually logs in, and this unit will not start at boot. Either set
          users.users.<name>.linger = true for the user at uid ${toString uid}, or
          confirm lingering is already enabled imperatively (`loginctl enable-linger`) outside
          this config -- nixpods cannot see that state and cannot avoid warning about it here.
        '')
        (lib.filterAttrs
          (_: uid: !(lib.any (u: u.linger or false)
            (lib.attrValues (lib.filterAttrs (_: u: (u.uid or null) == uid) config.users.users))))
          cfg.build.rootlessUids);
    })
  ];
}
