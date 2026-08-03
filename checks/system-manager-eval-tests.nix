# checks/system-manager-eval-tests.nix
#
# THE CLAIM UNDER TEST: a container declared once renders on the system-manager plane too, with
# no second declaration and no per-plane translation table. That claim is the reason
# modules/nixpods.nix is plane-neutral at all, and it is worth exactly nothing unevaluated -- so
# this file composes a REAL system-manager configuration through system-manager's own
# `lib.makeSystemConfig` (the same function a real host uses) and inspects what it renders.
#
# Same tier as checks/default.nix's NixOS eval tests: no VM, no activation. These prove the
# module system produces the right `systemd.packages`/`systemd.services`/`systemd.tmpfiles`
# entries and refuses the right configurations; they say nothing about a running host. The one
# thing this file DOES build for real is the generated unit package itself -- see the bottom.
#
# `makeSystemConfig` gates its entire return value on `config.assertions` passing (its own
# `returnIfNoAssertions`, called unconditionally while building `toplevel`) -- unlike NixOS's
# `eval-config.nix`, `.config` is unreachable when any assertion fails and the whole call throws.
# That is a faithful match for reality (a real host's own build throws identically), so the
# deliberately-failing fixture below is checked with `tryEval` confirming the throw, not by
# reading an assertions list after the fact.
{ pkgs, systemManagerModule, systemManagerLib }:

let
  lib = pkgs.lib;

  digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

  evalFor = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        systemManagerModule
        extraConfig
        { nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system; }
      ];
    }).config;

  evalFails = extraConfig: !(builtins.tryEval (builtins.seq (evalFor extraConfig).systemd.packages true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # A host on this plane says exactly what a NixOS host says. That is the whole point: this
  # fixture is copy-pasteable into checks/default.nix's NixOS eval and vice versa.
  ripperHost = {
    nixpods.ripper = {
      enable = true;
      outputDir = "/srv/rips";
      timeZone = "UTC";
      image.digest = digest;
    };
  };

  plainContainerHost = {
    nixpods.containers.web = {
      image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
      ports = [ "8080:80" ];
    };
  };

  # Rootless has nowhere to go on this plane -- system-manager's etc builder emits
  # `systemd/system` and nothing else, so the unit would be generated and installed nowhere.
  rootlessHost = {
    nixpods.containers.web = {
      image = { repository = "docker.io/library/nginx"; inherit digest; };
      rootless.uid = 1000;
    };
  };

  ripper = evalFor ripperHost;
  plain = evalFor plainContainerHost;

  results = [
    (check "system-manager/plain-container-evaluates"
      (plain.systemd.packages != [ ])
      "expected a declared container to install a generated unit package via systemd.packages; got: ${builtins.toJSON (map (p: p.name) plain.systemd.packages)}")

    (check "system-manager/units-package-lands-in-the-system-tree"
      (lib.any (p: p.name == "nixpods-quadlet-system") plain.systemd.packages)
      "systemd.packages: ${builtins.toJSON (map (p: p.name) plain.systemd.packages)}")

    (check "system-manager/wantedBy-drop-in-reaches-systemd.services"
      (
        let svc = plain.systemd.services.web;
        in svc.overrideStrategy == "asDropin" && svc.wantedBy == [ "multi-user.target" ]
      )
      "systemd.services.web: overrideStrategy=${plain.systemd.services.web.overrideStrategy}, wantedBy=${builtins.toJSON plain.systemd.services.web.wantedBy}")

    # The generated ExecStart must name the DISTRO's podman, not a nix-built second copy.
    (check "system-manager/podman-path-defaults-to-the-distro-binary"
      (plain.nixpods.podman.path == "/usr/bin/podman")
      "nixpods.podman.path: ${builtins.toJSON plain.nixpods.podman.path}")

    # ...and because no build can prove a path outside the store exists, the plane's earliest
    # honest check is registered instead of skipped.
    (check "system-manager/pre-activation-assertion-guards-that-path"
      (
        let a = plain.system-manager.preActivationAssertions.nixpods-podman;
        in a.enable && lib.hasInfix "/usr/bin/podman" a.script
      )
      "preActivationAssertions.nixpods-podman: ${builtins.toJSON plain.system-manager.preActivationAssertions.nixpods-podman}")

    (check "system-manager/rootless-is-refused-by-name-not-silently-dropped"
      (evalFails rootlessHost)
      "expected rootless.uid on the system-manager plane to fail evaluation -- this plane has no systemd --user tree, so the unit would be generated and installed nowhere")

    # ── the appliance, on the plane it is actually live on ────────────────────────────────
    (check "system-manager/ripper-renders-the-same-container-here"
      (
        let text = ripper.nixpods.containers.ripper.text;
        in lib.hasInfix "AddDevice=/dev/sr0:/dev/sr0" text
          && lib.hasInfix "Volume=/srv/rips:/out" text
          && lib.hasInfix "Type=oneshot" text
          && lib.hasInfix "PodmanArgs=--privileged" text
          && lib.hasInfix "Environment=TZ=UTC" text
      )
      "text: ${ripper.nixpods.containers.ripper.text}")

    (check "system-manager/ripper-is-not-wanted-by-anything"
      (ripper.systemd.services.ripper.wantedBy == [ ])
      "systemd.services.ripper.wantedBy: ${builtins.toJSON ripper.systemd.services.ripper.wantedBy}")

    # THE ONE THAT MATTERS MOST ON THIS PLANE: system-manager's activator calls
    # `ReloadOrRestartUnit` on every unit whose definition changed, without checking whether it
    # is running -- and reload-or-restart STARTS an inactive unit. Without X-RestartIfChanged=false
    # in the drop-in it parses, editing an unrelated option and redeploying would start a rip.
    (check "system-manager/ripper-deploy-does-not-count-as-a-trigger"
      (!ripper.systemd.services.ripper.restartIfChanged)
      "systemd.services.ripper.restartIfChanged: ${builtins.toJSON ripper.systemd.services.ripper.restartIfChanged}")

    (check "system-manager/ripper-directories-are-declared-through-tmpfiles"
      (lib.any (r: lib.hasInfix "/srv/rips" r) ripper.systemd.tmpfiles.rules)
      "tmpfiles.rules: ${builtins.toJSON ripper.systemd.tmpfiles.rules}")
  ];

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixpods system-manager eval tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
    ${report}
  ''
else
# Not just an eval: BUILD the unit package this plane's config produced, and read the generated
# unit back. This is the end-to-end proof of the repo's claim -- the same declaration, evaluated
# through system-manager's own module system rather than NixOS's, still runs the real generator
# and still produces a unit that calls the distro's podman.
  pkgs.runCommand "nixpods-system-manager-eval-tests"
  {
    units = ripper.nixpods.build.systemUnits;
    passedCount = toString (builtins.length results);
  }
    ''
      set -eu
      SVC="$units/lib/systemd/system/ripper.service"
      test -e "$SVC" || { echo "the system-manager plane did not produce ripper.service" >&2; ls -R "$units" >&2; exit 1; }

      grep -q '^ExecStart=/usr/bin/podman run' "$SVC" || { echo "the unit generated on the system-manager plane does not call the distro's podman" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^Type=oneshot$' "$SVC" || { echo "the ripper unit is not a completing job" >&2; cat "$SVC" >&2; exit 1; }
      grep -q -- '--device /dev/sr0:/dev/sr0' "$SVC" || { echo "the optical drive was not passed through" >&2; cat "$SVC" >&2; exit 1; }
      grep -q -- '--privileged' "$SVC" || { echo "the ripper unit lost --privileged" >&2; cat "$SVC" >&2; exit 1; }

      echo "all $passedCount nixpods system-manager eval tests passed, and the generated ripper.service was read back from a real generator run" > $out
    ''
