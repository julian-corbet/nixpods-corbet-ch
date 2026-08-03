# lib/render.nix
#
# Pure rendering: a resolved container/pod/network/volume option value (every option already at
# its final value -- this file never sees an unset option, exactly like nixvm's
# lib/domain-xml.nix) -> a Quadlet `.container`/`.pod`/`.network`/`.volume` INI document, as a
# plain string. No `config`, no NixOS module system, no derivations -- which is what lets
# checks/default.nix hit these functions directly with hand-built fixtures, no `nixosSystem` eval
# required, and lets modules/*.nix stay thin (call a renderer, hand its output to
# lib/build.nix's mkQuadletUnitPackage).
#
# THE TRANSLATION TABLE lives here, not in modules/*.nix, for the same reason nixfs keeps its
# filesystem/tool catalogue in `lib/`: which typed Nix option maps to which literal Quadlet `Key=`
# is DATA, and belongs next to the other pure data (lib/options.nix), not scattered across four
# option-declaring files.
{ lib }:

let
  # ── The generic INI renderer every unit kind below is built from ──────────────────────────
  #
  # A "section" is `{ name = "Container"; entries = [ { key = "Image"; value = ...; } ... ]; }`
  # -- entries as an ORDERED LIST, not an attrset, because several real Quadlet keys are
  # legitimately repeatable (`Environment=`, `Volume=`, `PublishPort=`, `AddCapability=`, ...) and
  # the systemd/Quadlet convention for a repeated key is literally repeating the `Key=Value`
  # line, which one attrset binding per key cannot express. `value = null` means "not set for
  # this object", so every renderer below can list its FULL key set unconditionally and let
  # "left at its default" mean "line omitted" -- no per-key `lib.optional` scattered through the
  # renderers themselves.
  # Nix's own `toString` renders `true`/`false` as "1"/"" (documented Nix coercion behavior),
  # which is not what an INI reader expects for a key documented as taking literal `true`/
  # `false` (Quadlet's `Internal=`, `NetworkDeleteOnStop=`, `DefaultDependencies=`, ...) --
  # booleans need their own branch; everything else (strings, ints) coerces the way you'd expect.
  mkValueString = value:
    if builtins.isBool value then (if value then "true" else "false")
    else toString value;

  mkLine = key: value: "${key}=${mkValueString value}";

  sectionLines = entries:
    lib.concatMap
      (e:
        if e.value == null then [ ]
        else if lib.isList e.value then map (mkLine e.key) e.value
        else [ (mkLine e.key e.value) ])
      entries;

  # Escape-hatch sections (lib/options.nix's `extraSectionOption`) are already plain
  # `attrsOf (either str (listOf str))` rather than ordered lists -- turn them into the same
  # entry shape so they can be appended to a typed section's own entries.
  extraEntries = attrs: lib.mapAttrsToList (key: value: { inherit key value; }) attrs;

  mkSection = name: entries:
    let lines = sectionLines entries;
    in lib.optionalString (lines != [ ]) (
      "[${name}]\n" + lib.concatStringsSep "\n" lines + "\n"
    );

  mkUnitText = sections:
    lib.concatStringsSep "\n" (lib.filter (s: s != "") (map ({ name, entries }: mkSection name entries) sections));
in
rec {
  inherit mkSection mkUnitText extraEntries;

  # ── Image pinning: the one translation table this repo is actually built around ───────────
  # THE QUESTION: given a repository, an optional human-readable tag, and an optional digest,
  # what literal string does Quadlet's `Image=` get? The tag is NEVER by itself sufficient to
  # resolve the image here -- see modules/containers.nix's assertion, which is what actually
  # enforces that a digest must be present unless a host explicitly opts out.
  mkImageRef = { repository, tag, digest, ... }:
    let
      tagPart = lib.optionalString (tag != null) ":${tag}";
      digestPart = lib.optionalString (digest != null) "@${digest}";
    in
    "${repository}${tagPart}${digestPart}";

  # ── [Container] ─────────────────────────────────────────────────────────────────────────
  renderContainer = name: cfg:
    let
      image = mkImageRef cfg.image;
    in
    mkUnitText [
      {
        name = "Unit";
        entries = [
          { key = "Description"; value = "nixpods container ${name}"; }
          { key = "StartLimitBurst"; value = cfg.restart.startLimitBurst; }
          { key = "StartLimitIntervalSec"; value = cfg.restart.startLimitIntervalSec; }
        ] ++ extraEntries cfg.extraUnitConfig;
      }
      {
        name = "Quadlet";
        entries = [
          { key = "DefaultDependencies"; value = if cfg.waitForNetworkOnline then null else false; }
        ];
      }
      {
        name = "Container";
        entries = [
          { key = "Image"; value = image; }
          { key = "Exec"; value = cfg.command; }
          { key = "Entrypoint"; value = cfg.entrypoint; }
          { key = "User"; value = cfg.user; }
          { key = "Pod"; value = if cfg.pod != null then "${cfg.pod}.pod" else null; }
          { key = "Network"; value = cfg.network; }
          { key = "Environment"; value = lib.mapAttrsToList (k: v: "${k}=${v}") cfg.environment; }
          { key = "Volume"; value = cfg.volumes; }
          { key = "AddDevice"; value = cfg.devices; }
          { key = "PublishPort"; value = cfg.ports; }
          { key = "HealthCmd"; value = cfg.health.cmd; }
          { key = "HealthInterval"; value = if cfg.health.cmd != null then cfg.health.interval else null; }
          { key = "HealthTimeout"; value = if cfg.health.cmd != null then cfg.health.timeout else null; }
          { key = "HealthRetries"; value = if cfg.health.cmd != null then cfg.health.retries else null; }
          { key = "HealthStartPeriod"; value = if cfg.health.cmd != null then cfg.health.startPeriod else null; }
        ] ++ extraEntries cfg.extraContainerConfig;
      }
      {
        name = "Service";
        entries = [
          # `Type=` is the ONE [Service] key quadlet itself validates rather than copying
          # through: it accepts `notify` (its own default, which it then implements with
          # `-d --sdnotify=conmon`) and `oneshot`, and rejects anything else by name at
          # generation time. `oneshot` is not a cosmetic relabelling -- the generator drops
          # `-d` and `--sdnotify=conmon` from the ExecStart it writes, so the container runs
          # in the FOREGROUND under systemd and the unit completes when the work does. That is
          # the difference between `systemctl start` returning immediately and `systemctl
          # start` returning the job's own exit status. Left unset (null) for a normal
          # long-running container, so quadlet's own default stands unmentioned.
          { key = "Type"; value = if cfg.oneshot then "oneshot" else null; }
          { key = "Restart"; value = cfg.restart.policy; }
          { key = "RestartSec"; value = cfg.restart.restartSec; }
        ] ++ extraEntries cfg.extraServiceConfig;
      }
    ];

  # ── [Pod] ───────────────────────────────────────────────────────────────────────────────
  renderPod = name: cfg:
    mkUnitText [
      {
        name = "Unit";
        entries = [
          { key = "Description"; value = "nixpods pod ${name}"; }
          { key = "StartLimitBurst"; value = cfg.restart.startLimitBurst; }
          { key = "StartLimitIntervalSec"; value = cfg.restart.startLimitIntervalSec; }
        ] ++ extraEntries cfg.extraUnitConfig;
      }
      {
        name = "Pod";
        entries = [
          { key = "Network"; value = cfg.network; }
          { key = "PublishPort"; value = cfg.ports; }
        ] ++ extraEntries cfg.extraPodConfig;
      }
      {
        name = "Service";
        entries = [
          { key = "Restart"; value = cfg.restart.policy; }
        ] ++ extraEntries cfg.extraServiceConfig;
      }
    ];

  # ── [Network] ───────────────────────────────────────────────────────────────────────────
  renderNetwork = name: cfg:
    mkUnitText [
      {
        name = "Unit";
        entries = [
          { key = "Description"; value = "nixpods network ${name}"; }
        ] ++ extraEntries cfg.extraUnitConfig;
      }
      {
        name = "Network";
        entries = [
          { key = "Driver"; value = cfg.driver; }
          { key = "Internal"; value = if cfg.internal then true else null; }
          { key = "Subnet"; value = cfg.subnet; }
          { key = "Gateway"; value = cfg.gateway; }
          { key = "NetworkDeleteOnStop"; value = true; }
        ] ++ extraEntries cfg.extraNetworkConfig;
      }
    ];

  # ── [Volume] ────────────────────────────────────────────────────────────────────────────
  renderVolume = name: cfg:
    mkUnitText [
      {
        name = "Unit";
        entries = [
          { key = "Description"; value = "nixpods volume ${name}"; }
        ] ++ extraEntries cfg.extraUnitConfig;
      }
      {
        name = "Volume";
        entries = extraEntries cfg.extraVolumeConfig;
      }
    ];
}
