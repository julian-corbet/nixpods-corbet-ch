# lib/options.nix
#
# Option fragments shared by every one of the four quadlet kinds (modules/containers.nix,
# modules/pods.nix, modules/networks.nix, modules/volumes.nix). Kept here, once, rather than
# retyped four times, for the same reason nixfs keeps its catalogue in `lib/`: these are data
# about the option SURFACE, cheap to read without a NixOS evaluation, and a change to (say) the
# rootless reasoning should not require editing four files in lockstep.
{ lib }:

rec {
  # THE ROOT/ROOTLESS DECISION, encoded as one option every kind carries.
  #
  # DECIDED DEFAULT: `null`, meaning ROOTFUL (the system-wide `podman-system-generator`, installed
  # via `systemd.packages` into the ONE root manager). This is not a placeholder -- it is the
  # considered default for this repo, for one concrete, verified reason:
  #
  # NixOS's per-user (`--user`) systemd manager does not run generators the way the system
  # manager does -- a nixpkgs maintainer put it plainly: user-generator support "is just clearly
  # not extended to user generators" on NixOS. A stock rootless-podman-quadlet setup on any other
  # distro relies on `systemd --user` invoking `podman-user-generator` itself at every user
  # session start; on NixOS that invocation never reliably happens, so the boot-time-generator
  # design this whole repo exists to avoid is not merely undesirable for rootless podman on
  # NixOS, it is often simply broken.
  #
  # Build-time synthesis sidesteps this completely, root or rootless alike: nixpods always runs
  # the SAME generator itself, at build time, and installs the resulting static `.service` files
  # through NixOS's `systemd.packages`. That option is system-level, but it is not system-manager-only
  # -- `nixos/lib/systemd-lib.nix`'s own `generateUnits` defaults `packages` to that same list
  # regardless of whether it is asked to scan a package's `lib/systemd/system/` (for the root
  # manager) or `lib/systemd/user/` (for a `--user` manager) subtree, and NixOS's user-unit
  # module (`nixos/modules/system/boot/systemd/user.nix`) reads exactly that when it composes
  # `/etc/systemd/user`. In other words: `systemd.packages` is the ONE list that feeds units to
  # BOTH manager instances, which is exactly why installing a rootless object's generated
  # `.service` there works at all on NixOS, generator brokenness notwithstanding.
  #
  # BE CAREFUL WITH THE ROOTLESS PATH ANYWAY. Sidestepping the generator does not sidestep
  # everything rootless podman needs to actually start at boot:
  #   - the target uid's systemd `--user` instance has to exist unprompted, which needs
  #     `users.users.<name>.linger = true` (this repo does not set it -- see the assertion below,
  #     and the operator's own user/uid management is out of this repo's scope, same boundary nixvm
  #     draws around bridges it never creates);
  #   - that uid needs a subuid/subgid range for user-namespaced containers (`--user` podman's
  #     own concern, not nixpods');
  #   - and quadlet's own implicit network-online wait, `podman-user-wait-network-online.service`,
  #     is a real, presently-open nixpkgs footgun for the rootless path specifically (see
  #     `restartOptions.waitForNetworkOnline` below and docs/gotchas.md).
  # None of that is invented worry -- it is why the default stays rootful until a host has an
  # actual reason (real privilege-separation need) to opt a specific object into rootless.
  rootlessOption = lib.mkOption {
    type = lib.types.nullOr lib.types.int;
    default = null;
    example = 1000;
    description = ''
      Numeric uid whose systemd **user** manager this unit installs into, instead of the one
      root **system** manager. NO DEFAULT beyond `null` (rootful) -- see this file's own header
      comment for the full reasoning, and the README's "root vs rootless" section for the short
      version.

      Rootful (`null`, the default) is the safe, fully-supported default for nixpods: one
      manager, no lingering session required, no subuid/subgid setup, and no dependence on
      NixOS's own limited user-generator support. Set this to a uid only when this specific
      workload genuinely needs rootless privilege separation, and only after that uid already
      has `users.users.<name>.linger = true` and a subuid/subgid range set up (nixpods asserts
      the former; see modules/default.nix).
    '';
  };

  # Escape hatch into a raw INI section this repo does not model a typed option for. Kept as
  # `attrsOf (either str (listOf str))`, not a single string, because most of what people reach
  # for here is exactly one more `Key=Value` line, and the list branch is what lets a repeatable
  # Quadlet key (there are many -- `AddCapability=`, `Annotation=`, ...) be added without hand-
  # rolling INI text. Prefer a typed option in modules/*.nix over this whenever the same knob
  # would plausibly get reused; this exists for the long tail, not as the primary interface.
  extraSectionOption = description: lib.mkOption {
    type = with lib.types; attrsOf (either str (listOf str));
    default = { };
    inherit description;
  };

  # Which systemd targets pull this unit in. Left generic (not autoStart-derived) because a
  # network/volume that is only ever reached transitively through a container's own `Network=`/
  # `Volume=` reference (Quadlet auto-wires that dependency -- see the man page's "Using network
  # units allows containers to depend on networks being automatically pre-created") has no
  # reason to also be wanted by a target directly; `[]` is the honest default for those two
  # kinds, while containers and pods -- the two kinds meant to run on their own -- default to
  # actually being wanted.
  wantedByOption = default: lib.mkOption {
    type = lib.types.listOf lib.types.str;
    inherit default;
    description = ''
      Which systemd targets this unit is wanted by. Installed as a drop-in
      (`overrideStrategy = "asDropin"`) onto the build-time-generated unit rather than rendered
      into the unit's own `[Install]` section -- Quadlet units in this repo carry no
      `[Install]` section at all; NixOS's own `systemd.services.<name>.wantedBy` /
      `systemd.user.services.<name>.wantedBy` mechanism is what actually wires activation, the
      same as any other NixOS-declared unit.
    '';
  };

  # Shared by containers AND pods (the two kinds meant to run continuously, as opposed to
  # networks/volumes' one-shot "make sure this exists" services) -- restart/backoff is the
  # same question for both: what does systemd do when the thing it supervises exits?
  # GENERATED, NOT RETYPED: every container or pod gets this exact four-key convention from one
  # typed submodule instead of each service definition hand-copying
  # `Restart=`/`RestartSec=`/`StartLimitBurst=`/`StartLimitIntervalSec=` boilerplate and, in
  # practice, drifting -- one host's copy-paste using `RestartSec=5`, another's using `3`, for no
  # reason anyone could reconstruct later.
  restartOption = lib.mkOption {
    type = lib.types.submodule {
      options = {
        policy = lib.mkOption {
          type = lib.types.enum [ "no" "on-failure" "always" "unless-stopped" ];
          default = "on-failure";
          description = ''
            systemd's own `Restart=` policy for the generated service. `on-failure` (the
            default) restarts on a non-zero exit or a signal/timeout/watchdog death, but not on
            a clean `podman stop`/exit 0 -- the convention this repo expects most long-running
            services to want. Pick `always` for something that must never stay down even after
            a clean exit, `no` for a genuine run-once job, `unless-stopped` to skip restarting
            after an operator-initiated stop specifically.
          '';
        };
        restartSec = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 5;
          description = "Seconds systemd waits before each restart attempt (`RestartSec=`).";
        };
        startLimitBurst = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 3;
          description = ''
            How many restarts within `startLimitIntervalSec` before systemd gives up and leaves
            the unit failed (`StartLimitBurst=`, a `[Unit]`-section key -- yes, distinct from the
            `[Service]`-section `Restart=` above; systemd's own split, not this repo's).
          '';
        };
        startLimitIntervalSec = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 600;
          description = "The rolling window `startLimitBurst` counts restarts over (`StartLimitIntervalSec=`).";
        };
      };
    };
    default = { };
    description = "Restart/backoff convention for this unit -- see the submodule's own option docs.";
  };
}
