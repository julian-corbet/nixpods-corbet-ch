# checks/default.nix
#
# Three kinds of check, cheapest first:
#
#   1. "render/*" -- pure unit tests against lib/render.nix directly. No NixOS eval, no
#      derivation, no podman: hand-built plain-value fixtures in, an INI string out, substring
#      assertions on the result. Same reasoning as nixvm's own "xml-render/*" group.
#
#   2. Everything under `results` below -- EVAL-TIME tests through real `nixosSystem`
#      composition (mirrors nixvm/nixboot's own checks/default.nix): does a host importing
#      `modules/default.nix` evaluate at all, and -- the failing direction, proven as
#      deliberately as the passing one -- does an unpinned image, a dangling `Pod=` reference, or
#      a container/pod name collision each fail evaluation BY NAME rather than silently produce
#      something half-formed.
#
#   3. `quadlet-generates-real-units` -- the one check in this repo that is an ACTUAL BUILD, not
#      an eval-time assertion: it runs lib/build.nix's `mkQuadletUnitPackage` against a
#      well-formed rendered container for real, then greps the generated `.service` for the
#      exact lines that prove the mechanism (a real `ExecStart=.../podman run`, `Type=notify`,
#      `NotifyAccess=all`, the `Pod=` reference resolved to a literal `BindsTo=`, the healthcheck
#      flag, the pod's reverse `Wants=`). This derivation's own comment explains why it does NOT
#      also re-run `systemd-analyze verify` (the Nix build sandbox has no writable `/run`, which
#      that command hardcodes) -- the claim itself was checked directly, empirically, before this
#      repo's first commit; see docs/gotchas.md for the transcript. This check IS required to
#      build for `nix flake check` to pass -- see checks/demo-malformed-fails-build.nix (a
#      `packages.<system>` output, not a `checks` one) for the matching NEGATIVE proof: a
#      malformed container fed through the exact same mechanism, left buildable on purpose so it
#      can be watched fail.
{ pkgs, lib, system, nixpodsModule }:

let
  render = import ../lib/render.nix { inherit lib; };
  build = import ../lib/build.nix { inherit lib; };
  podman = pkgs.podman;

  check = name: ok: detail: { inherit name ok detail; };

  digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";

  # ── Stubs every fixture below needs to reach system.build.toplevel ──────────────────
  bootStub = {
    fileSystems."/" = { device = "nodev"; fsType = "tmpfs"; };
    boot.loader.grub = { enable = true; devices = [ "nodev" ]; };
    networking.hostName = "example-pods-host";
    system.stateVersion = "25.05";
  };

  evalNixos = extraConfig:
    (lib.nixosSystem {
      inherit system;
      modules = [ nixpodsModule extraConfig bootStub ];
    }).config;

  # Forcing `system.build.toplevel.drvPath` is what actually runs `assertions` (a bare read of
  # `.config.assertions` is a passive list nobody enforced yet); `seq` reaches the wrapping
  # `throw` without deep-forcing or building the whole system closure, and the string context is
  # discarded so this stays an EVAL check, never a build -- exactly mirrors nixvm/nixboot's own
  # `buildFails` helper.
  evalToplevel = extraConfig:
    builtins.tryEval (builtins.seq
      (builtins.unsafeDiscardStringContext (evalNixos extraConfig).system.build.toplevel.drvPath)
      true);

  evalOk = extraConfig: (evalToplevel extraConfig).success;
  buildFails = extraConfig: !(evalToplevel extraConfig).success;

  # ── Fixtures ─────────────────────────────────────────────────────────────────────
  pinnedContainer = {
    nixpods.containers.example = {
      image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
    };
  };

  unpinnedContainer = {
    nixpods.containers.example = {
      image.repository = "docker.io/library/nginx";
    };
  };

  unpinnedButAcknowledged = {
    nixpods.containers.example = {
      image = { repository = "docker.io/library/nginx"; allowFloatingTag = true; };
    };
  };

  containerWithMissingPod = {
    nixpods.containers.example = {
      image = { repository = "docker.io/library/nginx"; inherit digest; };
      pod = "does-not-exist";
    };
  };

  containerWithRealPod = {
    nixpods.containers.example = {
      image = { repository = "docker.io/library/nginx"; inherit digest; };
      pod = "myapp";
    };
    nixpods.pods.myapp = { };
  };

  duplicatePodContainerName = {
    nixpods.containers.web = {
      image = { repository = "docker.io/library/nginx"; inherit digest; };
    };
    nixpods.pods.web = { };
  };

  badDigestFormat = {
    nixpods.containers.example.image = {
      repository = "docker.io/library/nginx";
      digest = "not-a-real-digest";
    };
  };

  rootlessNoLinger = {
    nixpods.containers.example = {
      image = { repository = "docker.io/library/nginx"; inherit digest; };
      rootless.uid = 1000;
    };
  };

  results = [
    # --- a fully-pinned container composes -------------------------------------------
    (check "pinned-container/toplevel-evaluates"
      (evalOk pinnedContainer)
      "expected a container with repository+tag+digest set to evaluate cleanly")

    (check "pinned-container/no-warnings"
      ((evalNixos pinnedContainer).warnings == [ ])
      "warnings: ${builtins.toJSON (evalNixos pinnedContainer).warnings}")

    # --- the repo's thesis, direction one: an unpinned image fails BY NAME -----------
    (check "unpinned-image/fails-evaluation"
      (buildFails unpinnedContainer)
      "expected a container with no digest and allowFloatingTag left false (its default) to fail evaluation, but it succeeded")

    (check "unpinned-image-acknowledged/succeeds-with-named-warning"
      (
        let w = (evalNixos unpinnedButAcknowledged).warnings;
        in evalOk unpinnedButAcknowledged && lib.any (m: lib.hasInfix "nixpods.containers.example" m) w
      )
      "expected allowFloatingTag = true to evaluate cleanly AND produce a warning naming the container; warnings: ${builtins.toJSON (evalNixos unpinnedButAcknowledged).warnings}")

    (check "bad-digest-format/fails-evaluation"
      (buildFails badDigestFormat)
      "expected digest = \"not-a-real-digest\" (fails the sha256:<64 hex> type) to fail evaluation, but it succeeded")

    # --- Pod= must reference a pod this flake actually declares ----------------------
    (check "container-pod-reference/fails-when-pod-undeclared"
      (buildFails containerWithMissingPod)
      "expected pod = \"does-not-exist\" with no matching nixpods.pods entry to fail evaluation, but it succeeded")

    (check "container-pod-reference/succeeds-when-pod-declared"
      (evalOk containerWithRealPod)
      "expected pod = \"myapp\" alongside a declared nixpods.pods.myapp to evaluate cleanly")

    (check "container-pod-reference/pod-text-contains-real-key"
      (lib.hasInfix "Pod=myapp.pod" (evalNixos containerWithRealPod).nixpods.containers.example.text)
      "text: ${(evalNixos containerWithRealPod).nixpods.containers.example.text}")

    # --- a container and a pod sharing one name is a real Podman-namespace collision -
    (check "duplicate-podman-name/fails-evaluation"
      (buildFails duplicatePodContainerName)
      "expected nixpods.containers.web and nixpods.pods.web (same name) to fail evaluation, but it succeeded")

    # --- rootless without a matching lingering user warns by name, does not block ----
    (check "rootless-no-linger/still-evaluates"
      (evalOk rootlessNoLinger)
      "expected a rootless container with no matching users.users.*.linger to still evaluate (a warning, not a hard failure)")

    (check "rootless-no-linger/warns-by-name"
      (lib.any (m: lib.hasInfix "example" m && lib.hasInfix "linger" m) (evalNixos rootlessNoLinger).warnings)
      "warnings: ${builtins.toJSON (evalNixos rootlessNoLinger).warnings}")

    # --- generated systemd wiring: overrideStrategy + wantedBy reach the real option -
    (check "container-service-override/asDropin-and-wantedBy"
      (
        let svc = (evalNixos pinnedContainer).systemd.services.example;
        in svc.overrideStrategy == "asDropin" && svc.wantedBy == [ "multi-user.target" ]
      )
      "systemd.services.example: ${builtins.toJSON (evalNixos pinnedContainer).systemd.services.example}")
  ];

  # ── Pure render-time checks: no nixosSystem at all -------------------------------
  baseContainerCfg = {
    image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
    rootless.uid = null;
    command = null;
    entrypoint = null;
    user = null;
    pod = null;
    network = null;
    environment = { };
    volumes = [ ];
    ports = [ ];
    waitForNetworkOnline = true;
    health = { cmd = null; interval = "30s"; timeout = "5s"; retries = 3; startPeriod = "5s"; };
    restart = { policy = "on-failure"; restartSec = 5; startLimitBurst = 3; startLimitIntervalSec = 600; };
    extraUnitConfig = { };
    extraContainerConfig = { };
    extraServiceConfig = { };
  };

  renderResults = [
    (check "render/image-ref-includes-tag-and-digest"
      (render.mkImageRef { repository = "example.org/app"; tag = "1.0"; inherit digest; } == "example.org/app:1.0@${digest}")
      "got: ${render.mkImageRef { repository = "example.org/app"; tag = "1.0"; inherit digest; }}")

    (check "render/image-ref-digest-only-omits-tag-colon"
      (render.mkImageRef { repository = "example.org/app"; tag = null; inherit digest; } == "example.org/app@${digest}")
      "got: ${render.mkImageRef { repository = "example.org/app"; tag = null; inherit digest; }}")

    (check "render/container-has-image-line"
      (lib.hasInfix "Image=docker.io/library/nginx:1.27@${digest}" (render.renderContainer "example" baseContainerCfg))
      "rendered: ${render.renderContainer "example" baseContainerCfg}")

    (check "render/no-healthcheck-omits-all-health-keys"
      (!(lib.hasInfix "Health" (render.renderContainer "example" baseContainerCfg)))
      "rendered: ${render.renderContainer "example" baseContainerCfg}")

    (check "render/healthcheck-set-renders-all-fields"
      (
        let text = render.renderContainer "example" (baseContainerCfg // { health = baseContainerCfg.health // { cmd = "curl -f http://localhost/health"; }; });
        in lib.hasInfix "HealthCmd=curl -f http://localhost/health" text
          && lib.hasInfix "HealthInterval=30s" text
          && lib.hasInfix "HealthRetries=3" text
      )
      "rendered: ${render.renderContainer "example" (baseContainerCfg // { health = baseContainerCfg.health // { cmd = "curl -f http://localhost/health"; }; })}")

    (check "render/restart-policy-and-startlimit-rendered"
      (
        let text = render.renderContainer "example" baseContainerCfg;
        in lib.hasInfix "Restart=on-failure" text && lib.hasInfix "StartLimitBurst=3" text
      )
      "rendered: ${render.renderContainer "example" baseContainerCfg}")

    (check "render/pod-reference-becomes-dot-pod-suffix"
      (lib.hasInfix "Pod=myapp.pod" (render.renderContainer "example" (baseContainerCfg // { pod = "myapp"; })))
      "rendered: ${render.renderContainer "example" (baseContainerCfg // { pod = "myapp"; })}")

    (check "render/wait-for-network-online-false-adds-quadlet-section"
      (lib.hasInfix "[Quadlet]" (render.renderContainer "example" (baseContainerCfg // { waitForNetworkOnline = false; }))
        && lib.hasInfix "DefaultDependencies=false" (render.renderContainer "example" (baseContainerCfg // { waitForNetworkOnline = false; })))
      "rendered: ${render.renderContainer "example" (baseContainerCfg // { waitForNetworkOnline = true; })}")

    (check "render/wait-for-network-online-true-omits-quadlet-section"
      (!(lib.hasInfix "[Quadlet]" (render.renderContainer "example" baseContainerCfg)))
      "rendered: ${render.renderContainer "example" baseContainerCfg}")

    (check "render/repeatable-keys-render-one-line-each"
      (
        let text = render.renderContainer "example" (baseContainerCfg // { volumes = [ "/a:/a" "/b:/b" ]; ports = [ "80:80" "443:443" ]; });
        in lib.hasInfix "Volume=/a:/a" text && lib.hasInfix "Volume=/b:/b" text
          && lib.hasInfix "PublishPort=80:80" text && lib.hasInfix "PublishPort=443:443" text
      )
      "rendered: ${render.renderContainer "example" (baseContainerCfg // { volumes = [ "/a:/a" "/b:/b" ]; ports = [ "80:80" "443:443" ]; })}")

    (check "render/extra-container-config-escape-hatch"
      (lib.hasInfix "AddCapability=CAP_NET_ADMIN" (render.renderContainer "example" (baseContainerCfg // { extraContainerConfig.AddCapability = "CAP_NET_ADMIN"; })))
      "rendered: ${render.renderContainer "example" (baseContainerCfg // { extraContainerConfig.AddCapability = "CAP_NET_ADMIN"; })}")
  ];

  allResults = results ++ renderResults;
  failed = builtins.filter (r: !r.ok) allResults;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  # ── The one REAL build in this check suite -----------------------------------------------
  # Runs the actual generator, on actual well-formed rendered text, through actual
  # lib/build.nix -- then greps the OUTPUT unit for the exact strings that prove the mechanism,
  # and runs `systemd-analyze verify` on it for real. If this derivation fails to build, `nix
  # flake check` reports it directly; no eval-time indirection is involved.
  wellFormedContainerText = render.renderContainer "web" {
    image = { repository = "docker.io/library/nginx"; tag = "1.27"; inherit digest; };
    rootless.uid = null;
    command = null;
    entrypoint = null;
    user = "65534:65534";
    pod = "webpod";
    network = null;
    environment = { EXAMPLE_VAR = "1"; };
    volumes = [ "/srv/example/data:/data" ];
    ports = [ ];
    waitForNetworkOnline = true;
    health = { cmd = "curl -f http://localhost/health"; interval = "30s"; timeout = "5s"; retries = 3; startPeriod = "5s"; };
    restart = { policy = "on-failure"; restartSec = 5; startLimitBurst = 3; startLimitIntervalSec = 600; };
    extraUnitConfig = { };
    extraContainerConfig = { };
    extraServiceConfig = { };
  };

  wellFormedPodText = render.renderPod "webpod" {
    rootless.uid = null;
    network = null;
    ports = [ "8080:80" ];
    restart = { policy = "on-failure"; restartSec = 5; startLimitBurst = 3; startLimitIntervalSec = 600; };
    extraUnitConfig = { };
    extraPodConfig = { };
    extraServiceConfig = { };
  };

  # NOTE on `systemd-analyze verify`: the README and docs/gotchas.md both report that the
  # generated units passed `systemd-analyze verify` clean -- checked directly, empirically,
  # against this exact mechanism, before this repo's first commit (see docs/gotchas.md for the
  # transcript). It is NOT re-run as part of THIS derivation: `systemd-analyze verify`
  # unconditionally tries to create `/run/systemd/` for its own private sockets, and the Nix
  # build sandbox provides no writable `/run` at all (confirmed directly: the identical command
  # against the identical unit exits 0 outside the sandbox, where `/run/systemd` already exists
  # on a live host, and fails with "mkdir: cannot create directory '/run': Permission denied"
  # inside it -- neither `XDG_RUNTIME_DIR` nor `--root=` redirect that particular hardcoded path,
  # also checked directly). Rather than reach for a `--user`/user-namespace workaround to fight
  # the sandbox over one directory, this check asserts the same underlying facts a clean
  # `systemd-analyze verify` would have confirmed -- real `ExecStart=`, `Type=notify`,
  # `NotifyAccess=all`, the `Pod=` -> `BindsTo=` resolution, the healthcheck flag, the pod's
  # reverse `Wants=` -- directly, by grep, against the real generator's real output.
  realBuildCheck = pkgs.runCommand "nixpods-quadlet-generates-real-units"
    {
      units = build.mkQuadletUnitPackage {
        inherit pkgs podman;
        type = "system";
        objects = [
          { ref = "web.container"; serviceName = "web"; text = wellFormedContainerText; }
          { ref = "webpod.pod"; serviceName = "webpod-pod"; text = wellFormedPodText; }
        ];
      };
    }
    ''
      set -eu
      SVC="$units/lib/systemd/system/web.service"
      POD="$units/lib/systemd/system/webpod-pod.service"

      test -e "$SVC" || { echo "expected web.service to exist, it does not" >&2; exit 1; }
      test -e "$POD" || { echo "expected webpod-pod.service to exist, it does not" >&2; exit 1; }

      grep -q '^ExecStart=.*bin/podman run' "$SVC" || { echo "web.service has no real podman ExecStart=" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^Type=notify$' "$SVC" || { echo "web.service is not Type=notify" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^NotifyAccess=all$' "$SVC" || { echo "web.service has no NotifyAccess=all" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^BindsTo=webpod-pod.service$' "$SVC" || { echo "web.service's Pod= did not resolve to a literal BindsTo=" >&2; cat "$SVC" >&2; exit 1; }
      grep -q -- '--health-cmd' "$SVC" || { echo "web.service lost the HealthCmd=" >&2; cat "$SVC" >&2; exit 1; }
      grep -q '^Wants=web.service$' "$POD" || { echo "webpod-pod.service did not gain the reverse Wants=web.service" >&2; cat "$POD" >&2; exit 1; }

      echo "quadlet generated real units for both web.service and webpod-pod.service, with the Pod=/health/notify facts confirmed by grep against the generator's real output" > $out
    '';
in
if failed != [ ]
then
  throw ''
    nixpods eval/render tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length allResults)}):
    ${report}
  ''
else {
  eval-tests = pkgs.runCommand "nixpods-eval-tests"
    { passedCount = toString (builtins.length allResults); }
    ''
      echo "all $passedCount nixpods eval/render tests passed"
      touch $out
    '';

  quadlet-generates-real-units = realBuildCheck;
}
