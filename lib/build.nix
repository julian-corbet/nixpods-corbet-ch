# lib/build.nix
#
# THE MECHANISM. Everything else in this repo is policy wrapped around this one function.
#
# `podman`'s `quadlet` binary IS the systemd generator NixOS would otherwise let run at boot
# (`podman-system-generator` / `podman-user-generator` are plain symlinks to the same `quadlet`
# binary) -- verified on this session's build host:
#
#     $ find $(nix build --print-out-paths nixpkgs#podman)/lib/systemd -iname '*generator*'
#     .../lib/systemd/system-generators/podman-system-generator
#     .../lib/systemd/user-generators/podman-user-generator
#
# and it is a PURE OFFLINE TRANSLATOR: no root, no running podman daemon, no network. Feed it a
# directory of `.container`/`.pod`/`.network`/`.volume` INI files via the `QUADLET_UNIT_DIRS`
# environment variable it reads, and it writes real `systemd.service` unit files -- the exact
# same units that would land in `/run/systemd/generator/` at boot on a plain quadlet setup, just
# produced now, by `pkgs.runCommand`, at eval-adjacent build time instead. Empirically checked
# this session: a plain `.container` with a digest-pinned `Image=` renders a unit with
# `Type=notify`, `NotifyAccess=all`, and a literal `ExecStart=.../podman run ...` line; a
# `Pod=some.pod` reference resolves to a literal `BindsTo=some-pod.service` / `After=some-pod.service`
# pair in the container's own `[Unit]` section (and the reverse `Wants=`/`Before=` in the pod's) --
# no placeholder, no runtime indirection. The generated unit passed `systemd-analyze verify`
# clean with no extra flags.
#
# THE ASSERTION THIS FUNCTION ADDS, AND WHY IT IS LOAD-BEARING. The generator's own exit code is
# not a reliable success signal: this session found multiple malformed inputs (an unrecognized
# key, a line with no `=`, an empty file) that make it exit non-zero -- which a bare
# `pkgs.runCommand` invocation would already catch, since Nix build scripts run under `set -e` --
# but systemd's generator CONTRACT (see systemd.generator(5)) forbids a generator from ever
# aborting the boot it runs during: at real boot time this same binary, run by systemd itself
# rather than by us, is permitted to log a warning and simply omit the one broken unit while
# every other generator (and the rest of the boot) proceeds regardless of its exit code. That is
# the precise shape of nixpkgs issue #498524: a quadlet-injected unit dependency nobody asked for
# went unsatisfied and hung the boot for 60+ seconds, and nothing at build time had looked hard
# enough to notice, because nothing asserted that what was EXPECTED was what actually GOT
# EMITTED. Checking the generator's exit code is necessary but not sufficient; checking that
# every `.service` file we asked for actually exists on disk afterward is what turns "the
# generator silently did less than we asked" into a build failure instead of a 3am "Unit
# some-name.service not found" page. This is a POSITIVE assertion (presence), not merely a
# negative one (non-zero exit) -- the two catch different failure shapes and neither substitutes
# for the other.
#
# VENDORED, NOT DEPENDED ON. This function is a re-implementation of
# `mirkolenz/quadlet-nix`'s `lib.nix::mkQuadletUnitPackage`
# (https://github.com/mirkolenz/quadlet-nix, MIT-licensed) -- read there first if you want the
# upstream shape this was built from. It is not pulled in as a flake input: at the time this repo
# was written that project was an 8-star repo created the same year with no production use
# outside its own test suite, and this exact ~90-line technique is core mechanism for nixpods,
# not a dependency nixpods should be one `flake.lock` bump away from losing control of.
{ lib }:

{
  # `type` is podman's own vocabulary for which systemd manager instance a unit belongs to --
  # "system" (the one root manager; rootFUL) or "user" (a per-uid --user manager; rootLESS). It
  # is not our word; it is the literal subdirectory name both podman (`lib/systemd/${type}-generators/`)
  # and NixOS's own `systemd.packages` scan (`lib/systemd/${type}/`, see nixpkgs
  # `nixos/lib/systemd-lib.nix`'s `generateUnits`) already agree on, so passing it straight
  # through keeps this function honest about which of the two it is asking for.
  #
  # `objects` is a list of `{ ref, text, serviceName }`: `ref` is the quadlet source filename
  # (e.g. "myapp.container"), `text` is its full INI-format unit text, `serviceName` is the
  # `.service` file the generator is expected to produce from it (almost always `${name}.service`
  # for a container, `${name}-pod.service` for a pod -- see lib/render.nix, which is the one
  # place in this repo that computes these three fields from typed options).
  mkQuadletUnitPackage =
    { pkgs
    , podman
    , type
    , objects
    , name ? "nixpods-quadlet-${type}"
    , directoryName ? "nixpods-quadlet-units-${type}"
    }:
    let
      outDir = "$out/lib/systemd/${type}";
      services = map (obj: "${obj.serviceName}.service") objects;
    in
    pkgs.runCommand name
      {
        # The generator reads ONLY this env var for its input directory -- no other
        # configuration surface exists, which is exactly what makes it safe to drive from a
        # `runCommand` builder that has no root, no podman socket, and no network reachable.
        QUADLET_UNIT_DIRS = pkgs.symlinkJoin {
          name = directoryName;
          paths = map (obj: pkgs.writeTextDir obj.ref obj.text) objects;
        };
      }
      ''
        mkdir -p "${outDir}"
        "${lib.getLib podman}/lib/systemd/${type}-generators/podman-${type}-generator" "${outDir}"

        for service in ${lib.escapeShellArgs services}; do
          if [ ! -e "${outDir}/$service" ]; then
            echo "nixpods: the podman quadlet generator did not emit $service from its own input -- refusing to install a partially-generated unit set. Re-run with QUADLET_UNIT_DIRS=<dir> ${lib.getLib podman}/lib/systemd/${type}-generators/podman-${type}-generator --dryrun <dir> to see the generator's own diagnostic for the unit that produced this." >&2
            exit 1
          fi
        done
      '';
}
