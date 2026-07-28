# modules/default.nix
#
# THE WIRING. Every other module in this directory only declares typed options and renders INI
# text (lib/render.nix); this file is the one place that actually:
#
#   1. collects every enabled container/pod/network/volume's { ref; text; serviceName; } plus
#      which systemd manager it belongs to (root vs the given uid's --user instance),
#   2. hands each group to lib/build.nix's `mkQuadletUnitPackage`, which runs podman's REAL
#      quadlet generator inside the Nix build sandbox and asserts every expected `.service` was
#      actually produced,
#   3. installs the result via `systemd.packages` (root and rootless both -- see
#      lib/options.nix's `rootlessOption` for why the same NixOS mechanism covers both), and
#   4. wires each unit's `wantedBy` as a drop-in (`overrideStrategy = "asDropin"`) onto the
#      already-generated unit, rather than baking an `[Install]` section into the rendered text.
#
# Nothing here ever runs podman, starts a container, or touches the network -- see the repo
# README's "Boundaries" section for why that boundary is deliberate.
{ lib, config, pkgs, ... }:

let
  cfg = config.nixpods;
  build = import ../lib/build.nix { inherit lib; };

  podman = config.virtualisation.podman.package or pkgs.podman;

  # Every declared object, from all four kinds, each already carrying { ref; serviceName; text;
  # rootless.uid; wantedBy; enable; } -- the four modules that define these submodules agree on
  # this shape on purpose, so this file can treat "a container" and "a volume" identically from
  # here on.
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
  # the uid only matters for the linger warning below.
  mkUnits = type: objects: build.mkQuadletUnitPackage {
    inherit pkgs podman type objects;
    name = "nixpods-quadlet-${type}";
    directoryName = "nixpods-quadlet-units-${type}";
  };

  rootfulUnits = mkUnits "system" rootfulObjects;
  rootlessUnits = mkUnits "user" rootlessObjects;

  # NOTE: `obj.serviceName` here, with NO ".service" appended -- `systemd.services.<name>` /
  # `systemd.user.services.<name>` both already imply the suffix themselves (NixOS appends it
  # when generating the real unit file); the on-disk file lib/build.nix looks for IS
  # "${obj.serviceName}.service" (see its own `services = map (obj: "${obj.serviceName}.service")
  # objects` line), but that is a filename, not this attribute name, and the two must not be
  # confused the way an early draft of this file did.
  mkOverride = obj: lib.nameValuePair obj.serviceName {
    overrideStrategy = "asDropin";
    wantedBy = obj.wantedBy;
  };

  rootfulOverrides = lib.listToAttrs (map mkOverride rootfulObjects);
  rootlessOverrides = lib.listToAttrs (map mkOverride rootlessObjects);

  # ── cross-kind sanity: two independent checks quadlet-nix's own modules/common.nix makes,
  # kept here because they are a property of the WHOLE collection, not of any one kind ─────────
  duplicatePodmanNames = lib.intersectLists (lib.attrNames cfg.containers) (lib.attrNames cfg.pods);

  duplicateServiceNames =
    let
      names = map (o: o.serviceName) enabledObjects;
      counts = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } names;
    in
    lib.attrNames (lib.filterAttrs (_: count: count > 1) counts);

  # ── the rootless linger reminder: nixpods never manages user accounts (out of scope, same
  # boundary nixvm draws around bridges it never creates) but a lingering-less uid's --user
  # manager will not exist unprompted at boot, so a unit installed there silently never starts --
  # exactly the "undiagnosable until later" failure this whole repo exists to avoid elsewhere.
  # Best-effort: warn by object name whenever the uid does not resolve to a `users.users.*`
  # entry with `linger = true` in THIS config; says nothing about lingering managed imperatively
  # (`loginctl enable-linger`) outside NixOS, which this cannot see and does not warn about.
  lingerWarnings = lib.flatten (map
    (o:
      let
        matches = lib.filterAttrs (_: u: (u.uid or null) == o.rootless.uid) config.users.users;
        lingering = lib.any (u: u.linger or false) (lib.attrValues matches);
      in
      lib.optional (!lingering) ''
        nixpods: ${o.serviceName} installs into uid ${toString o.rootless.uid}'s systemd --user
        manager (rootless.uid is set), but no users.users.<name> entry in this config has that
        uid with linger = true. Without lingering, that uid's --user manager does not exist
        until someone actually logs in, and this unit will not start at boot. Either set
        users.users.<name>.linger = true for the user at uid ${toString o.rootless.uid}, or
        confirm lingering is already enabled imperatively (`loginctl enable-linger`) outside
        this config -- nixpods cannot see that state and cannot avoid warning about it here.
      '')
    rootlessObjects);
in
{
  imports = [
    ./containers.nix
    ./pods.nix
    ./networks.nix
    ./volumes.nix
  ];

  config = lib.mkIf (enabledObjects != [ ]) {
    virtualisation.podman.enable = lib.mkDefault true;

    systemd.packages =
      lib.optional (rootfulObjects != [ ]) rootfulUnits
      ++ lib.optional (rootlessObjects != [ ]) rootlessUnits;

    systemd.services = rootfulOverrides;
    systemd.user.services = rootlessOverrides;

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

    warnings = lingerWarnings;
  };
}
