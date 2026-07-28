# modules/volumes.nix
#
# `nixpods.volumes.<name>` -- a named Podman volume, pre-created declaratively rather than
# implicitly by whichever container happens to reference it first. The thinnest of the four
# kinds: nothing about a volume's own identity needs a typed option beyond root-vs-rootless
# (lib/options.nix) -- everything else genuinely is the escape hatch, so this module is close to
# nothing more than that.
{ lib, ... }:

let
  render = import ../lib/render.nix { inherit lib; };
  opts = import ../lib/options.nix { inherit lib; };

  volumeType = lib.types.submodule ({ name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this volume is generated and installed at all.";
      };

      rootless.uid = opts.rootlessOption;

      wantedBy = opts.wantedByOption [ ];

      extraUnitConfig = opts.extraSectionOption "Escape hatch into this unit's [Unit] section for keys not modeled above.";
      extraVolumeConfig = opts.extraSectionOption "Escape hatch into this unit's [Volume] section for keys not modeled above (e.g. Driver=, Image=, UID=, GID=).";

      ref = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
      serviceName = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
      text = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
    };

    config = {
      ref = "${name}.volume";
      serviceName = "${name}-volume";
      text = render.renderVolume name config;
    };
  });
in
{
  options.nixpods.volumes = lib.mkOption {
    type = lib.types.attrsOf volumeType;
    default = { };
    description = ''
      Podman named volumes declared as build-time-rendered Quadlet units. Referencing one from
      `nixpods.containers.<name>.volumes = [ "<name>.volume:/mnt/path" ]` gets Quadlet's own
      automatic unit dependency for free -- see podman-systemd.unit(5)'s Volume= note; this
      module does not re-wire that dependency itself.
    '';
  };
}
