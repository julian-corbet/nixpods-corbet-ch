# modules/nixpods.nix
#
# THE WIRING, and everything about it that is TRUE ON EVERY PLANE. Every other module in this
# directory only declares typed options and renders INI text (lib/render.nix); this file is the
# one place that actually:
#
#   1. collects every enabled container/pod/network/volume's { ref; text; serviceName; } plus
#      which systemd manager it belongs to (root vs the given uid's --user instance),
#   2. hands each group to lib/build.nix's `mkQuadletUnitPackage`, which runs podman's REAL
#      quadlet generator inside the Nix build sandbox and asserts every expected `.service` was
#      actually produced,
#   3. installs the ROOTFUL result via `systemd.packages`, and
#   4. wires each unit's `wantedBy` and `restartIfChanged` as a drop-in
#      (`overrideStrategy = "asDropin"`) onto the already-generated unit, rather than baking an
#      `[Install]` section into the rendered text.
#
# WHY THIS FILE IS PLANE-NEUTRAL, AND IS NOT ITSELF THE MODULE YOU IMPORT. nixpods runs on two
# evaluation planes: NixOS (`nixosModules.nixpods`) and system-manager on a foreign distro
# (`systemManagerModules.nixpods`). One declaration serves both, because every step above is
# already plane-neutral -- and specifically because `systemd.packages` means the same thing in
# both, which was read out of both implementations rather than assumed:
#
#   - NixOS's `nixos/lib/systemd-lib.nix::generateUnits` scans each package's
#     `lib/systemd/system/` and links what it finds into the unit tree;
#   - system-manager's `nix/modules/systemd.nix` builds `/etc/systemd/system` with a literal
#     `for package in $packages; do for hook in $package/lib/systemd/system/*; do ln -s ...`,
#     and applies the same "if the unit already came from a package, install my definition as
#     `<unit>.d/overrides.conf` instead" rule NixOS's `asDropin` produces.
#
# So the generated package installs unchanged on both, and so does the drop-in that carries
# `wantedBy`. What does NOT survive the crossing is small and lives in the two backend modules
# next to this one: `virtualisation.podman.*` is a NixOS-only namespace, system-manager has no
# `systemd.user.*` tree at all (its etc builder emits `systemd/system` and nothing else -- so
# rootless is a hard assertion there, not a silent no-op), and a foreign distro's podman is its
# own package rather than one this config installs. Hence `nixpods.podman.path` below.
#
# Nothing here ever runs podman, starts a container, or touches the network -- see the repo
# README's "Boundaries" section for why that boundary is deliberate.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixpods;
  build = import ../lib/build.nix { inherit lib; };

  # Every declared object, from all four kinds, each already carrying { ref; serviceName; text;
  # rootless.uid; wantedBy; restartIfChanged; enable; } -- the four modules that define these
  # submodules agree on this shape on purpose, so this file can treat "a container" and "a
  # volume" identically from here on.
  allObjects = lib.concatLists [
    (lib.attrValues cfg.containers)
    (lib.attrValues cfg.pods)
    (lib.attrValues cfg.networks)
    (lib.attrValues cfg.volumes)
  ];

  enabledObjects = lib.filter (o: o.enable) allObjects;

  rootfulObjects = lib.filter (o: o.rootless.uid == null) enabledObjects;
  rootlessObjects = lib.filter (o: o.rootless.uid != null) enabledObjects;

  # Rootless objects further split BY uid: each uid gets its own `--user` manager instance, and
  # `systemd.packages` scanning does not care which uid a `lib/systemd/user/*.service` file was
  # meant for -- the unit lands in the ONE shared `/etc/systemd/user` tree NixOS's own
  # `nixos/modules/system/boot/systemd/user.nix` composes for every `--user` instance alike (see
  # lib/options.nix's rootlessOption comment). What DOES need to be per-uid is which
  # `systemd.user.services` override each unit's `wantedBy` lands on, which is already keyed by
  # serviceName below regardless of uid, so no further split is actually needed for THAT part --
  # the uid only matters for the linger warning the NixOS backend raises.
  mkUnits = type: objects: build.mkQuadletUnitPackage {
    inherit pkgs type objects;
    podman = cfg.podman.package;
    podmanPath = cfg.podman.path;
    name = "nixpods-quadlet-${type}";
    directoryName = "nixpods-quadlet-units-${type}";
  };

  # NOTE: `obj.serviceName` here, with NO ".service" appended -- `systemd.services.<name>` /
  # `systemd.user.services.<name>` both already imply the suffix themselves (NixOS appends it
  # when generating the real unit file); the on-disk file lib/build.nix looks for IS
  # "${obj.serviceName}.service" (see its own `services = map (obj: "${obj.serviceName}.service")
  # objects` line), but that is a filename, not this attribute name -- the two must not be
  # confused.
  mkOverride = obj: lib.nameValuePair obj.serviceName {
    overrideStrategy = "asDropin";
    inherit (obj) wantedBy restartIfChanged;
  };

  # ── cross-kind sanity: two independent checks quadlet-nix's own modules/common.nix makes,
  # kept here because they are a property of the WHOLE collection, not of any one kind ─────────
  duplicatePodmanNames = lib.intersectLists (lib.attrNames cfg.containers) (lib.attrNames cfg.pods);

  duplicateServiceNames =
    let
      names = map (o: o.serviceName) enabledObjects;
      counts = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } names;
    in
    lib.attrNames (lib.filterAttrs (_: count: count > 1) counts);
in
{
  imports = [
    ./containers.nix
    ./pods.nix
    ./networks.nix
    ./volumes.nix
    ./ripper.nix
  ];

  options.nixpods.podman = {
    # TWO DIFFERENT PODMANS, ON PURPOSE -- the one that GENERATES and the one that RUNS.
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.podman;
      defaultText = lib.literalExpression "pkgs.podman";
      description = ''
        The podman package whose quadlet binary translates this config's `.container`/`.pod`/
        `.network`/`.volume` text into real units, inside the Nix build sandbox. Always a Nix
        package: there is no other way to run a translator at BUILD time, which is the whole
        point of this repo.

        Its version decides the flag vocabulary of the generated `ExecStart=` line, so on a host
        where `podman.path` points at a foreign distro's own podman, keep the two on the same
        major version.
      '';
    };

    path = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/usr/bin/podman";
      description = ''
        Absolute path to the podman binary the GENERATED units should invoke, when that is not
        the same binary as `package`. `null` (the default, and always right on NixOS) means the
        generated `ExecStart=` names `package`'s own store path.

        Set this on a foreign distro managed by system-manager, where podman is the distro's own
        package: pointing the units at a second, nix-built podman would put two copies of the CLI
        on one host, sharing one `/var/lib/containers` and free to disagree about its on-disk
        format. The system-manager backend defaults this to `/usr/bin/podman` for that reason.

        Nothing at build time can prove a path outside the store exists -- so the system-manager
        backend also registers a pre-activation assertion for it, which is the earliest a foreign
        path can honestly be checked at all.
      '';
    };
  };

  # ── computed, read-only: what the per-plane backends next to this file install ─────────────
  options.nixpods.build = {
    systemUnits = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      internal = true;
      readOnly = true;
      description = "Generated rootful units, or null when nothing rootful is declared.";
    };
    userUnits = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      internal = true;
      readOnly = true;
      description = "Generated rootless units, or null when nothing rootless is declared. Installable only on a plane that has a systemd --user tree.";
    };
    userOverrides = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      internal = true;
      readOnly = true;
      description = "`systemd.user.services` drop-ins carrying wantedBy/restartIfChanged for the rootless units.";
    };
    rootlessUids = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      internal = true;
      readOnly = true;
      description = "serviceName -> uid for every rootless object, so a backend can warn (or refuse) by name without reaching into the submodules.";
    };
  };

  config = lib.mkMerge [
    # Defined unconditionally, not under the `mkIf` below: these four are how the per-plane
    # backends ask "is there anything to install, and what", so they have to answer honestly on
    # a host that declared nothing. (They carry no `default` either -- nixpkgs counts an option's
    # default as one of its definitions, and a `readOnly` option with both a default and an
    # assignment is refused as "set multiple times".)
    {
      nixpods.build = {
        systemUnits = if rootfulObjects == [ ] then null else mkUnits "system" rootfulObjects;
        userUnits = if rootlessObjects == [ ] then null else mkUnits "user" rootlessObjects;
        userOverrides = lib.listToAttrs (map mkOverride rootlessObjects);
        rootlessUids = lib.listToAttrs (map (o: lib.nameValuePair o.serviceName o.rootless.uid) rootlessObjects);
      };
    }

    (lib.mkIf (enabledObjects != [ ]) {
      systemd.packages = lib.optional (rootfulObjects != [ ]) config.nixpods.build.systemUnits;
      systemd.services = lib.listToAttrs (map mkOverride rootfulObjects);

      assertions = [
        {
          assertion = duplicatePodmanNames == [ ];
          message = ''
            nixpods: the same name (${lib.concatStringsSep ", " duplicatePodmanNames}) is used for
            both a container and a pod. Quadlet derives each object's own Podman resource name
            from this attribute name (systemd-<name>); a container and a pod sharing one would
            collide in Podman's own namespace. Rename one of them.
          '';
        }
        {
          assertion = duplicateServiceNames == [ ];
          message = ''
            nixpods: more than one declared object resolves to the same systemd service name
            (${lib.concatStringsSep ", " duplicateServiceNames}). Every container/pod/network/
            volume across nixpods.containers, nixpods.pods, nixpods.networks and nixpods.volumes
            must produce a unique <serviceName>.service -- rename one of the colliding objects.
          '';
        }
      ];
    })
  ];
}
