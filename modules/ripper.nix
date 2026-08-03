# modules/ripper.nix
#
# `nixpods.ripper` -- an optical-disc ripper (rix1337/docker-ripper) as an on-demand podman job
# bound to a physical drive. The first APPLIANCE in this repo: a module that answers "which
# image, which flags, which unit semantics" for one specific workload, and then renders itself
# into `nixpods.containers.<name>` like any other caller would.
#
# WHY AN APPLIANCE BELONGS IN A TRANSLATOR REPO AT ALL. The README's "Boundaries" section already
# says what nixpods is for: a workload that is single-host BY NATURE -- real local state, a
# hardware dependency, an identity welded to one machine. A disc ripper is that statement in its
# purest form; the drive is a device node on one desk. What makes it an appliance rather than a
# few lines in a host's own config is that "how do you rip a disc with this image" is MECHANISM,
# not a value: the image name, the two mount points it expects, the PUID/PGID/TZ contract it
# reads, the device passthrough, the `--privileged` its rip tools' raw SG_IO ioctls actually
# need, and the run-to-completion unit shape. None of that is a fact about any particular
# machine, and all of it is identical on every host that ever wants the job. Left in a host's own
# config it gets retyped once per host and once per plane, and copies of a twenty-flag podman
# invocation drift silently -- two that agree on every option NAME can still disagree about
# whether the unit waits for the rip to finish.
#
# THE ESTATE-SPECIFIC PART STAYS OUT. Where the rips land (`outputDir`), which device node the
# drive enumerates as, which uid/gid owns the files, which timezone stamps the logs: values, no
# defaults invented here beyond what is a genuine convention rather than somebody's choice.
#
# ON-DEMAND BY DESIGN, AND THAT COSTS THREE SETTINGS, NOT ONE:
#   - `wantedBy = [ ]`     -- nothing pulls it in at boot; the operator starts it when a disc is
#                             actually in the drive.
#   - `oneshot = true`     -- the container runs in the FOREGROUND under systemd, so
#                             `systemctl start <name>` blocks until the rip is done and reports
#                             its exit status. The `manual-latest` image variant rips the
#                             inserted disc on start rather than polling the drive, which is what
#                             makes a completing job the right shape here.
#   - `restartIfChanged = false`
#                          -- a deploy that changes this unit must not COUNT AS A TRIGGER.
#                             system-manager's activator calls `ReloadOrRestartUnit` on every
#                             unit whose definition changed without checking whether it is
#                             running, and `reload-or-restart` starts an inactive unit: without
#                             this, editing `outputDir` and redeploying would start a rip.
#
# Whether the image is digest-pinned is deliberately NOT decided here. `image` is the same
# submodule `nixpods.containers.<name>.image` uses, so this appliance inherits the repo's own
# assertion: a host enabling it either pins a digest or says `allowFloatingTag = true` out loud
# and carries the warning. An appliance that quietly floated its own image would be the one hole
# through which everything this repo argues for leaks out.
{ lib, config, ... }:

let
  cfg = config.nixpods.ripper;
  opts = import ../lib/options.nix { inherit lib; };
in
{
  options.nixpods.ripper = {
    enable = lib.mkEnableOption "an on-demand optical-disc ripper as a podman job (off unless started by hand)";

    name = lib.mkOption {
      type = lib.types.str;
      default = "ripper";
      description = ''
        The `nixpods.containers.<name>` this appliance renders into -- which is also the systemd
        unit name (`<name>.service`) and, via Quadlet, the Podman container name
        (`systemd-<name>`).

        Worth an option rather than a constant precisely because this unit is started by hand:
        for an on-demand job, `systemctl start <name>` IS the operator interface, so a host that
        already has that name in its fingers is entitled to keep it.
      '';
    };

    image = opts.imageOption {
      repository = "docker.io/rix1337/docker-ripper";
      tag = "manual-latest";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/sr0";
      example = "/dev/sr1";
      description = ''
        Host optical drive device node, passed into the container (`AddDevice=`, rendered as
        `--device`). `/dev/sr0` is the kernel's name for the first optical drive on any Linux
        box, hotplug USB drives included -- a convention, not an assumption about a machine.
      '';
    };

    outputDir = lib.mkOption {
      type = lib.types.path;
      example = "/srv/rips";
      description = ''
        Host directory the ripped output is written to (the container's `/out`). NO DEFAULT: a
        rip lands somewhere in a content tree that only the host knows the shape of, and the
        wrong guess writes tens of gigabytes into the wrong filesystem.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ripper";
      description = "Host directory for the ripper's own config/state (the container's `/config`).";
    };

    puid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = ''
        UID the container performs file operations as (`PUID`, this image's own convention).
        Defaults to 1000 -- the first ordinary user on a Linux system, and what the image itself
        assumes -- so that ripped files land owned by a person rather than by root.
      '';
    };

    pgid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "GID the container performs file operations as (`PGID`, this image's own convention).";
    };

    timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "America/Los_Angeles";
      description = ''
        `TZ` inside the container -- it stamps rip logs and, for some titles, filenames. `null`
        (the default) passes no `TZ` at all and leaves the image on UTC. A timezone is a fact
        about where a machine sits, so this module refuses to pick one.
      '';
    };

    privileged = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the container privileged (`--privileged`). The default is `true` because the rip
        tools inside the image issue raw SG_IO ioctls to the drive, which a plain
        device-passthrough does not permit; a leaner profile is a matter of finding the specific
        capabilities that still rip, not of asserting they exist.
      '';
    };

    extraPodmanArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--memory=4g" ];
      description = ''
        Extra raw podman flags appended to this container's `PodmanArgs=`. Exists so a host can
        add one without colliding with the `--privileged` this module already puts there --
        Quadlet has no typed key for either, and two definitions of one INI key is a conflict,
        not a merge.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The rip target and the state directory have to exist, owned by the uid the container writes
    # as, BEFORE the job starts -- podman would otherwise create the bind-mount source itself,
    # owned by root, and the in-container PUID would then fail to write into it. tmpfiles is the
    # declarative way to say that on both planes this repo targets (system-manager implements
    # `systemd.tmpfiles.rules` with NixOS's own syntax), rather than a `mkdir`/`chown` prologue
    # inside the unit that re-runs on every single start.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${toString cfg.puid} ${toString cfg.pgid} - -"
      "d ${cfg.outputDir} 0775 ${toString cfg.puid} ${toString cfg.pgid} - -"
    ];

    nixpods.containers.${cfg.name} = {
      inherit (cfg) image;

      oneshot = true;
      wantedBy = [ ];
      restartIfChanged = false;
      # A rip that failed is a disc to look at, not a job to retry: a second automatic attempt on
      # a scratched disc burns another half hour and reports the same failure.
      restart.policy = "no";

      devices = [ "${cfg.device}:${cfg.device}" ];

      volumes = [
        "${cfg.outputDir}:/out"
        "${cfg.stateDir}:/config"
      ];

      environment = {
        PUID = toString cfg.puid;
        PGID = toString cfg.pgid;
      } // lib.optionalAttrs (cfg.timeZone != null) { TZ = cfg.timeZone; };

      extraContainerConfig = {
        # `cdrom` is resolved against the CONTAINER's user database, not the host's -- this image
        # is Ubuntu-based and defines it. A host whose own optical group is named something else
        # (Arch calls it `optical`) is therefore not a reason to change this.
        GroupAdd = "cdrom";
      } // lib.optionalAttrs (cfg.privileged || cfg.extraPodmanArgs != [ ]) {
        PodmanArgs = lib.optional cfg.privileged "--privileged" ++ cfg.extraPodmanArgs;
      };
    };
  };
}
