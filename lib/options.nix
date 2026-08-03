# lib/options.nix
#
# Option fragments shared by every one of the four quadlet kinds (modules/containers.nix,
# modules/pods.nix, modules/networks.nix, modules/volumes.nix) and by the appliance modules that
# render themselves into one (modules/ripper.nix). Kept here, once, rather than retyped four
# times, for the same reason nixfs keeps its catalogue in `lib/`: these are data about the option
# SURFACE, cheap to read without a NixOS evaluation, and a change to (say) the rootless reasoning
# should not require editing four files in lockstep.
{ lib }:

rec {
  # THE IMAGE-PINNING SUBMODULE. Lives here, not inline in modules/containers.nix, because an
  # appliance module (modules/ripper.nix) also has to answer "which image, pinned how" -- and if
  # it answered with its own hand-rolled `image` option, this repo would ship a second, laxer
  # notion of image pinning that modules/containers.nix's digest assertion never sees. One
  # submodule, one assertion, no appliance able to opt itself out of the repo's own thesis.
  #
  # `defaults` supplies a default for `repository`/`tag` where a module genuinely knows the
  # answer (an appliance knows exactly which image does its job); `{ }` leaves `repository`
  # mandatory, which is what a generic container wants -- guessing a repository there would be
  # the drift-by-typo this repo exists to catch, not commit. A digest is NEVER defaulted, for
  # either caller: the digest is the one field whose value is a fact about a moment in time.
  imageOption = defaults: lib.mkOption {
    description = "Which image this container runs, and how it is pinned -- see the submodule's own option docs.";
    type = lib.types.submodule {
      options = {
        repository = lib.mkOption ({
          type = lib.types.str;
          example = "docker.io/library/nginx";
          description = ''
            THE QUESTION: which image repository does this container run? No default unless an
            appliance module supplied one -- guessing a repository here would be exactly the kind
            of silent drift-by-typo this repo exists to catch, not commit.
          '';
        } // lib.optionalAttrs (defaults ? repository) { default = defaults.repository; });

        tag = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = defaults.tag or null;
          example = "1.27.3";
          description = ''
            A human-readable tag, kept purely for changelog/diff legibility and for tools
            (Renovate and similar) that track upstream releases by tag. NEVER authoritative
            on its own -- `digest` below is what actually resolves the pull; a tag with no
            digest is exactly the floating reference this repo exists to catch (see
            `allowFloatingTag`).
          '';
        };

        digest = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "sha256:[0-9a-f]{64}");
          default = null;
          example = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
          description = ''
            THE QUESTION THIS OPTION ANSWERS: which exact bytes does this container run,
            regardless of what the registry serves under `tag` tomorrow? This is the reason
            nixpods exists at all -- without a digest, Podman (and Quadlet's own `AutoUpdate=`)
            resolve `tag` at PULL time, so the exact image running on a host is whatever the
            registry currently happens to serve under that name: drift that is, from this Nix
            config's own perspective, indistinguishable from "nothing changed". NO DEFAULT. See
            `allowFloatingTag` for the one deliberate opt-out, and modules/containers.nix's own
            assertion for what happens if neither is set.
          '';
        };

        allowFloatingTag = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Explicit acknowledgement: run this container from `tag` alone, with no digest,
            accepting that the registry can move the bits under this host with no corresponding
            change to this Nix config. Default `false` on purpose -- THE POINT of nixpods is that
            a container's image does not move unless a commit says so. Setting this `true` is
            reported in `warnings` by container name every build, so a host that took this
            shortcut is never quietly indistinguishable from one that pinned properly.
          '';
        };
      };
    };
  };

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
      the former; see modules/nixos.nix).
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

  # WHAT A DEPLOY DOES TO A UNIT WHOSE DEFINITION CHANGED -- a different question from
  # `restart.policy` above, which is what the SUPERVISOR does when a running container exits.
  # Both activation tools this repo targets read the same key out of the unit's own `[Service]`
  # section: NixOS's switch-to-configuration-ng
  # (`parse_systemd_bool(new_unit_info, "Service", "X-RestartIfChanged", true)`) and
  # system-manager's activator (identical call, identical section) -- read from both sources,
  # not assumed from one.
  #
  # THE FAILURE THIS EXISTS TO PREVENT is on the system-manager plane specifically. Its activator
  # calls `ReloadOrRestartUnit` on every unit whose store path changed, without first checking
  # whether that unit is running -- and `reload-or-restart` STARTS an inactive unit. For an
  # on-demand unit (`wantedBy = [ ]`, the operator starts it by hand when the hardware is
  # actually there) that turns "I edited an unrelated option and redeployed" into "the job ran".
  # NixOS's own switch is less trigger-happy here, but the key is honoured on both planes, so
  # one setting covers both.
  restartIfChangedOption = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Whether an activation (`nixos-rebuild switch` / `system-manager switch`) may restart this
      unit when its definition changed. Rendered as `X-RestartIfChanged=false` in the drop-in
      nixpods already installs for `wantedBy` -- not in the Quadlet source text, because it is
      the activation tool, not podman, that reads it.

      Leave `true` for a long-running service: a changed definition should take effect. Set
      `false` for a unit that is started on demand and does real work when it starts -- see this
      file's own comment for the failure that prevents.
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
  # systemd's own `Restart=` vocabulary, not Podman's. The distinction is load-bearing rather
  # than pedantic: `unless-stopped` is a real Docker/Podman restart policy and NOT a systemd one,
  # and systemd does not reject an unknown value -- it logs `Failed to parse
  # Restart=unless-stopped, ignoring: Invalid argument` and falls back to `Restart=no`. A unit
  # asking to be kept alive would therefore quietly never be restarted, which is the exact
  # "silently did less than we asked" shape this repo exists to catch. Since a `.container`'s
  # `[Service]` keys are copied through to the generated unit verbatim (quadlet validates
  # `[Container]` keys, not `[Service]` ones -- see docs/gotchas.md), the type is the only place
  # that check can happen at all.
  restartPolicies = [ "no" "on-success" "on-failure" "on-abnormal" "on-abort" "on-watchdog" "always" ];

  # systemd refuses to LOAD a `Type=oneshot` unit whose `Restart=` is `always` or `on-success`
  # ("Service has Restart= set to either always or on-success, which isn't allowed for
  # Type=oneshot services. Refusing.") -- verified against `systemd-analyze verify` for all seven
  # policies, see docs/gotchas.md. That failure lands at unit-load time on the host, which is
  # precisely the 3am discovery nixpods exists to move to build time; modules/containers.nix
  # asserts against this list instead.
  oneshotRestartPolicies = [ "no" "on-failure" "on-abnormal" "on-abort" "on-watchdog" ];

  restartOption = lib.mkOption {
    type = lib.types.submodule {
      options = {
        policy = lib.mkOption {
          type = lib.types.enum restartPolicies;
          default = "on-failure";
          description = ''
            systemd's own `Restart=` policy for the generated service. `on-failure` (the
            default) restarts on a non-zero exit or a signal/timeout/watchdog death, but not on
            a clean `podman stop`/exit 0 -- the convention this repo expects most long-running
            services to want. Pick `always` for something that must never stay down even after
            a clean exit, `no` for a genuine run-once job.

            These are systemd's values, not Podman's: Podman's own `unless-stopped` policy has
            no systemd equivalent and is deliberately absent from this enum -- see this file's
            own comment above for what systemd does with an unrecognised one.
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
