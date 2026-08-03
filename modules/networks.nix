# modules/networks.nix
#
# `nixpods.networks.<name>` -- a named Podman network, pre-created declaratively rather than
# implicitly by whichever container happens to reference it first. Deliberately thin: a network
# has no image, no health, no restart policy of its own (its generated service is a one-shot
# "make sure this network exists" unit, per podman-systemd.unit(5)) -- the only real per-network
# policy question is root vs rootless, shared with every other kind (lib/options.nix).
{ lib, ... }:

let
  render = import ../lib/render.nix { inherit lib; };
  opts = import ../lib/options.nix { inherit lib; };

  networkType = lib.types.submodule ({ name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this network is generated and installed at all.";
      };

      rootless.uid = opts.rootlessOption;

      driver = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "bridge" "macvlan" "ipvlan" ]);
        default = null;
        description = "Quadlet `Driver=`. `null` (the default) leaves Podman's own default (`bridge`) in place.";
      };

      internal = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Restrict this network from reaching outside the host (Quadlet `Internal=`).";
      };

      subnet = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.168.90.0/24";
        description = "Quadlet `Subnet=`. `null` leaves Podman's own IPAM allocation in place.";
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Quadlet `Gateway=`. Only meaningful alongside `subnet`.";
      };

      restartIfChanged = opts.restartIfChangedOption;

      wantedBy = opts.wantedByOption [ ];

      extraUnitConfig = opts.extraSectionOption "Escape hatch into this unit's [Unit] section for keys not modeled above.";
      extraNetworkConfig = opts.extraSectionOption "Escape hatch into this unit's [Network] section for keys not modeled above.";

      ref = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
      serviceName = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
      text = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
    };

    config = {
      ref = "${name}.network";
      serviceName = "${name}-network";
      text = render.renderNetwork name config;
    };
  });
in
{
  options.nixpods.networks = lib.mkOption {
    type = lib.types.attrsOf networkType;
    default = { };
    description = ''
      Podman networks declared as build-time-rendered Quadlet units. Referencing one from
      `nixpods.containers.<name>.network = "<name>.network"` gets Quadlet's own automatic
      unit dependency for free -- see podman-systemd.unit(5)'s "Using network units" note; this
      module does not re-wire that dependency itself.
    '';
  };
}
