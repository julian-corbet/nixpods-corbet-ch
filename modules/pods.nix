# modules/pods.nix
#
# `nixpods.pods.<name>` -- a shared network/IPC namespace multiple containers join via their own
# `nixpods.containers.<name>.pod`. Kept deliberately small next to containers.nix: a pod has no
# image to pin and no in-container process to health-check, so the only real policy questions
# left are root-vs-rootless (shared with containers, see lib/options.nix) and restart/backoff
# (same convention as containers, same submodule).
{ lib, ... }:

let
  render = import ../lib/render.nix { inherit lib; };
  opts = import ../lib/options.nix { inherit lib; };

  podType = lib.types.submodule ({ name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this pod is generated and installed at all.";
      };

      rootless.uid = opts.rootlessOption;

      network = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "host";
        description = "Raw Quadlet `Network=` value for the pod's shared network namespace.";
      };

      ports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "8080:80" ];
        description = ''
          Raw `[HOST_IP:]HOSTPORT:CONTAINERPORT` publish specs (Quadlet `PublishPort=`,
          repeatable) at the POD level -- publish here, not on an individual member container,
          when the port belongs to the pod's shared network namespace rather than to one
          container specifically.
        '';
      };

      restart = opts.restartOption;

      restartIfChanged = opts.restartIfChangedOption;

      wantedBy = opts.wantedByOption [ "multi-user.target" ];

      extraUnitConfig = opts.extraSectionOption "Escape hatch into this unit's [Unit] section for keys not modeled above.";
      extraPodConfig = opts.extraSectionOption "Escape hatch into this unit's [Pod] section for keys not modeled above.";
      extraServiceConfig = opts.extraSectionOption "Escape hatch into this unit's [Service] section for keys not modeled above.";

      ref = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
      serviceName = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
      text = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
    };

    config = {
      ref = "${name}.pod";
      serviceName = "${name}-pod";
      text = render.renderPod name config;
    };
  });
in
{
  options.nixpods.pods = lib.mkOption {
    type = lib.types.attrsOf podType;
    default = { };
    description = "Podman pods declared as build-time-rendered Quadlet units -- a shared network/IPC namespace containers join via `nixpods.containers.<name>.pod`.";
  };
}
