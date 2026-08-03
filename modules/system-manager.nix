# modules/system-manager.nix
#
# The system-manager plane: a foreign distro (Arch, Debian, Ubuntu) whose systemd this config
# writes units into without owning the OS underneath. `modules/nixpods.nix` next to this file
# already did all the real work -- and it genuinely is the same work here, because
# system-manager's `systemd.packages` implements the identical contract NixOS's does (read out of
# `nix/modules/systemd.nix`: it links every `$package/lib/systemd/system/*` into
# `/etc/systemd/system`, and turns a Nix-side definition of a unit a package already provided
# into `<unit>.d/overrides.conf`, which is precisely what `overrideStrategy = "asDropin"` means
# on NixOS). A container declared once therefore renders on both planes with no second
# declaration and no per-plane translation table.
#
# What this file adds is the three things that are NOT the same, each of them a place where
# assuming NixOS would have produced a silent failure rather than an error:
#
#   1. PODMAN IS THE DISTRO'S, NOT THIS CONFIG'S. There is no `virtualisation.podman.enable` here
#      -- that namespace does not exist on this plane, and installing a nix-built podman anyway
#      would put a second copy of the CLI beside the distro's own, both writing one
#      `/var/lib/containers`. So the generated units are pointed at `/usr/bin/podman` and the
#      distro keeps ownership of the package.
#
#   2. NOTHING AT BUILD TIME CAN PROVE A PATH OUTSIDE THE STORE EXISTS. The whole thesis of this
#      repo is that a broken input fails at build time rather than at 3am -- but "is podman
#      installed on that host" is not a question a build can answer about a foreign distro. The
#      earliest honest answer is system-manager's own pre-activation assertion hook, which runs
#      on the target before anything is switched: a host without podman fails its deploy, by
#      name, instead of leaving a unit that will not start behind.
#
#   3. THERE IS NO `systemd --user` TREE. system-manager's etc builder emits `systemd/system` and
#      nothing else, so a rootless object here would be generated, installed nowhere, and never
#      run. That is refused by name below rather than silently dropped.
{ lib, config, ... }:

let
  cfg = config.nixpods;
  enabled = cfg.build.systemUnits != null || cfg.build.userUnits != null;
  rootlessNames = lib.attrNames cfg.build.rootlessUids;
in
{
  imports = [ ./nixpods.nix ];

  config = lib.mkMerge [
    {
      # UNCONDITIONAL, deliberately: gate this on "is anything declared" and the module system
      # deadlocks -- answering that question means building the units, and the units are built
      # around this very path. Setting it always costs nothing on a host that declares no
      # containers.
      nixpods.podman.path = lib.mkDefault "/usr/bin/podman";
    }

    (lib.mkIf enabled {
      system-manager.preActivationAssertions.nixpods-podman = {
        enable = true;
        script = ''
          if [ ! -x "${cfg.podman.path}" ]; then
            echo "nixpods: ${cfg.podman.path} is missing or not executable on this host."
            echo "Every unit nixpods generates here invokes it by that absolute path, so activating"
            echo "would install units that cannot start. Install this distro's own podman package,"
            echo "or point nixpods.podman.path at wherever it actually lives."
            exit 1
          fi
        '';
      };

      assertions = [
        {
          assertion = rootlessNames == [ ];
          message = ''
            nixpods: ${lib.concatStringsSep ", " rootlessNames} set rootless.uid, but this is the
            system-manager plane, which has no systemd --user unit tree at all -- its etc builder
            emits /etc/systemd/system and nothing else. The unit would be generated correctly,
            installed nowhere, and never run: a silent gap of exactly the kind this repo exists to
            turn into an error. Leave rootless.uid null (rootful, the default) on this plane, or
            run that workload on a NixOS host where nixpods can install a user unit for real.
          '';
        }
      ];
    })
  ];
}
