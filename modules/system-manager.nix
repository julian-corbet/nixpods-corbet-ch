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
#      The same hook answers a second question that only this plane has: WHICH PODMAN. The flags
#      in a generated `ExecStart=` are the vocabulary of the podman that WROTE them, and on this
#      plane that is not the podman that runs them -- so a host generating with one major version
#      and running another is asking one podman to execute another's command line. That is checked
#      here too (`nixpods.podman.requireMatchingMajor`), for the same reason and at the same
#      moment, because the target's own podman version is not knowable any earlier either.
#
#   3. THERE IS NO `systemd --user` TREE. system-manager's etc builder emits `systemd/system` and
#      nothing else, so a rootless object here would be generated, installed nowhere, and never
#      run. That is refused by name below rather than silently dropped.
{ lib, config, ... }:

let
  cfg = config.nixpods;
  enabled = cfg.build.systemUnits != null || cfg.build.userUnits != null;
  rootlessNames = lib.attrNames cfg.build.rootlessUids;

  # The major version of the podman whose quadlet binary writes this host's `ExecStart=` lines.
  # Known at build time, because that one IS a Nix package -- which is precisely why the OTHER half
  # of the comparison has to wait for the target.
  generatingMajor = lib.versions.major cfg.podman.package.version;

  # POSIX sh only, and deliberately so: this runs inside system-manager's own pre-activation hook on
  # a foreign distro, where nothing about the shell environment is this config's to assume. No awk,
  # no sed, no grep -- `${var##* }` and `${var%%.*}` are shell built-ins everywhere.
  #
  # `podman --version` prints "podman version 6.0.2": the format string is `%s version %s`, read
  # out of the podman binary itself rather than remembered. If it ever stops being that, the parse
  # falls through to the "could not read a version" branch below, which reports and does NOT block
  # -- a deploy must not fail because a diagnostic changed shape.
  versionCheckScript = ''
    running_raw=$("${cfg.podman.path}" --version 2>/dev/null || true)
    running_version=''${running_raw##* }
    running_major=''${running_version%%.*}

    case "$running_major" in
      ""|*[!0-9]*)
        echo "nixpods: could not read a version out of \`${cfg.podman.path} --version\` (got: \"$running_raw\")."
        echo "The generator/runtime major-version check is being skipped rather than blocking this"
        echo "deploy on a parse failure. This host generates its units with podman ${generatingMajor}.x;"
        echo "confirm by hand that ${cfg.podman.path} is on the same major version."
        ;;
      "${generatingMajor}")
        ;;
      *)
        echo "nixpods: this host GENERATES its units with podman ${generatingMajor}.x"
        echo "(nixpods.podman.package = ${cfg.podman.package.name}) and RUNS them with podman"
        echo "$running_version (${cfg.podman.path})."
        echo ""
        echo "Those are different major versions. Every generated ExecStart= line was written in the"
        echo "GENERATING podman's flag vocabulary, because that is the binary that wrote it -- so"
        echo "activating would install units that ask podman $running_major to execute podman"
        echo "${generatingMajor}'s command line. A flag that moved between the two fails at container"
        echo "start, on this host, after a build that succeeded."
        echo ""
        echo "Either align the two -- pin nixpods.podman.package to the major version this distro"
        echo "ships, or update the distro's podman -- or, if this skew is understood and accepted,"
        echo "set nixpods.podman.requireMatchingMajor = false, which keeps this report and drops the"
        echo "refusal."
        ${lib.optionalString cfg.podman.requireMatchingMajor "exit 1"}
        ;;
    esac
  '';
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

      # A SEPARATE assertion rather than more lines in the one above, on purpose: "podman is not
      # installed" and "podman is a different major version than the one that wrote these units" are
      # two distinct findings with two distinct fixes, and a host reading a failed deploy should be
      # told which one it hit without having to parse a combined script's output.
      system-manager.preActivationAssertions.nixpods-podman-version = {
        enable = true;
        script = versionCheckScript;
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
