# modules/containers.nix
#
# `nixpods.containers.<name>` -- the main policy-bearing surface of this repo. Every option here
# renders to a real Quadlet `[Container]`/`[Unit]`/`[Service]` key via lib/render.nix; nothing in
# this file talks to podman, systemd, or the generator directly -- see modules/default.nix for
# where the rendered text actually becomes a package and gets installed.
{ lib, config, ... }:

let
  render = import ../lib/render.nix { inherit lib; };
  opts = import ../lib/options.nix { inherit lib; };

  cfg = config.nixpods.containers;

  containerType = lib.types.submodule ({ name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this container is generated and installed at all.";
      };

      # ── image pinning: see the repo README's "image pinning" section for the full case ────
      image = lib.mkOption {
        description = "Which image this container runs, and how it is pinned -- see the submodule's own option docs.";
        type = lib.types.submodule {
          options = {
            repository = lib.mkOption {
              type = lib.types.str;
              example = "docker.io/library/nginx";
              description = ''
                THE QUESTION: which image repository does this container run? NO DEFAULT --
                guessing a repository here would be exactly the kind of silent drift-by-typo
                this repo exists to catch, not commit.
              '';
            };
            tag = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
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
                nixpods exists at all -- without a digest, Podman (and Quadlet's own
                `AutoUpdate=`) resolve `tag` at PULL time, so the exact image running on a host
                is whatever the registry currently happens to serve under that name: drift that
                is, from this Nix config's own perspective, indistinguishable from "nothing
                changed". NO DEFAULT. See `allowFloatingTag` for the one deliberate opt-out, and
                this module's own assertion (below) for what happens if neither is set.
              '';
            };
            allowFloatingTag = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Explicit acknowledgement: run this container from `tag` alone, with no digest,
                accepting that the registry can move the bits under this host with no
                corresponding change to this Nix config. Default `false` on purpose -- THE POINT
                of nixpods is that a container's image does not move unless a commit says so.
                Setting this `true` is reported in `warnings` by container name every build, so a
                host that took this shortcut is never quietly indistinguishable from one that
                pinned properly.
              '';
            };
          };
        };
      };

      # ── root vs rootless: see lib/options.nix's rootlessOption for the full reasoning ──────
      rootless.uid = opts.rootlessOption;

      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "--config /etc/example/example.toml";
        description = ''
          Arguments appended after the image (Quadlet `Exec=`, systemd command-line syntax) --
          added to the image's own ENTRYPOINT/CMD, not a replacement for it. `null` (the
          default) runs the image exactly as it defines itself.
        '';
      };

      entrypoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Override the image's own ENTRYPOINT (Quadlet `Entrypoint=`). Rarely needed; prefer `command` when the image's own entrypoint is fine as-is.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "65534:65534";
        description = ''
          Which user (name, or numeric `uid[:gid]`) Podman runs the process as INSIDE the
          container (Quadlet `User=`) -- unrelated to `rootless.uid` above, which instead picks
          WHICH SYSTEMD MANAGER owns this unit. A rootful unit (`rootless.uid = null`, the
          default) can and usually should still run its in-container process as an unprivileged
          user via this option; the two knobs answer different questions and are set
          independently.
        '';
      };

      pod = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of a `nixpods.pods.<name>` this container joins (Quadlet `Pod=`). Resolved to a
          literal `BindsTo=`/`After=` pair on the generated unit at BUILD time, not a runtime
          lookup -- see lib/build.nix's header for how this was verified. Must name a pod
          actually declared in `nixpods.pods`; enforced by this module's own assertion.
        '';
      };

      network = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "host";
        description = ''
          Raw Quadlet `Network=` value: `"host"`, `"none"`, or `"<name>.network"` for a
          `nixpods.networks.<name>` declared alongside this container. `null` (the default)
          leaves Podman's own default network behavior in place.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables set inside the container (Quadlet `Environment=`, one rendered line per entry).";
      };

      volumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/srv/example/data:/data" ];
        description = "Raw `SRC:DEST[:OPTIONS]` bind/volume specs (Quadlet `Volume=`, repeatable).";
      };

      ports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "8080:80" ];
        description = "Raw `[HOST_IP:]HOSTPORT:CONTAINERPORT` publish specs (Quadlet `PublishPort=`, repeatable).";
      };

      waitForNetworkOnline = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether Quadlet adds its usual implicit network-readiness dependency to this unit
          (`network-online.target` rootful, `podman-user-wait-network-online.service`
          rootless). Default `true` matches upstream Quadlet behavior. Turn this OFF only for a
          container known to start fine before the network is up: the rootless side of this
          wait is a live, open nixpkgs footgun (see docs/gotchas.md) where the wait service can
          time out for reasons unrelated to this container and add 60+ seconds to every start --
          exactly the class of bug this repo exists to catch at build time rather than at 3am.
          Rendered as `DefaultDependencies=false` in the generated unit's own `[Quadlet]`
          section -- a real, distinct section from the same-named `[Unit]` key, which systemd
          itself defines with a different meaning; see podman-systemd.unit(5).
        '';
      };

      health = lib.mkOption {
        description = "Liveness-check convention for this container -- see the submodule's own option docs.";
        type = lib.types.submodule {
          options = {
            cmd = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                THE QUESTION: what command, run inside the container, proves it is actually
                alive -- not merely that its PID exists (Quadlet `HealthCmd=`)? NO DEFAULT: a
                healthcheck nixpods invented on this service's behalf would be a fake signal;
                only the service itself knows what liveness means for it. `null` (the default)
                means no healthcheck at all, and every other option in this submodule is then
                inert -- omitted from the rendered unit entirely, not rendered with a
                meaningless value.
              '';
            };
            interval = lib.mkOption {
              type = lib.types.str;
              default = "30s";
              description = "How often the health command re-runs once healthy (Quadlet `HealthInterval=`). Inert if `cmd` is unset.";
            };
            timeout = lib.mkOption {
              type = lib.types.str;
              default = "5s";
              description = "How long a single health command run may take before counting as a failure (Quadlet `HealthTimeout=`). Inert if `cmd` is unset.";
            };
            retries = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 3;
              description = "Consecutive failures before the container is marked unhealthy (Quadlet `HealthRetries=`). Inert if `cmd` is unset.";
            };
            startPeriod = lib.mkOption {
              type = lib.types.str;
              default = "5s";
              description = "Grace period after start during which failures don't count yet (Quadlet `HealthStartPeriod=`). Inert if `cmd` is unset.";
            };
          };
        };
        default = { };
      };

      restart = opts.restartOption;

      wantedBy = opts.wantedByOption [ "multi-user.target" ];

      extraUnitConfig = opts.extraSectionOption "Escape hatch into this unit's [Unit] section for keys not modeled above.";
      extraContainerConfig = opts.extraSectionOption "Escape hatch into this unit's [Container] section for keys not modeled above.";
      extraServiceConfig = opts.extraSectionOption "Escape hatch into this unit's [Service] section for keys not modeled above.";

      # ── computed, read-only -- consumed by modules/default.nix ─────────────────────────────
      ref = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; description = "The Quadlet source filename this container renders to."; };
      serviceName = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; description = "The systemd service name (without .service) the generator is expected to produce."; };
      text = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; description = "The rendered .container INI text."; };
    };

    config = {
      ref = "${name}.container";
      serviceName = name;
      text = render.renderContainer name config;
    };
  });
in
{
  options.nixpods.containers = lib.mkOption {
    type = lib.types.attrsOf containerType;
    default = { };
    description = ''
      Podman containers declared as build-time-rendered Quadlet units. Each one becomes a real
      `<name>.service` unit, produced by actually running podman's own quadlet generator inside
      the Nix build sandbox -- see the repo README and lib/build.nix for the full mechanism.
    '';
  };

  config = {
    assertions = lib.flatten (lib.mapAttrsToList
      (n: c: [
        {
          assertion = !c.enable || c.image.digest != null || c.image.allowFloatingTag;
          message = ''
            nixpods.containers.${n}.image: no digest set, and allowFloatingTag is false (its
            default). This container would run from
            "${c.image.repository}${lib.optionalString (c.image.tag != null) ":${c.image.tag}"}"
            alone -- a tag Podman resolves at PULL time, so the exact bits that land on this host
            are whatever the registry currently serves under that name, indistinguishable from
            Nix's own perspective from "nothing changed". Pin an image digest
            (nixpods.containers.${n}.image.digest = "sha256:...") or, if this container
            genuinely must float, set nixpods.containers.${n}.image.allowFloatingTag = true and
            accept the warning that comes with it.
          '';
        }
        {
          assertion = !c.enable || c.pod == null || (config.nixpods.pods ? ${c.pod});
          message = ''
            nixpods.containers.${n}.pod points at "${if c.pod == null then "" else c.pod}", which
            is not declared in nixpods.pods. Quadlet's Pod= only resolves to a real
            BindsTo=/After= pair against a pod unit this same flake actually generates --
            declare nixpods.pods.${if c.pod == null then "<name>" else c.pod} alongside this
            container, or point `pod` at one that already exists.
          '';
        }
      ])
      cfg);

    warnings = lib.flatten (lib.mapAttrsToList
      (n: c: lib.optional (c.enable && c.image.digest == null && c.image.allowFloatingTag) ''
        nixpods.containers.${n}: running from an unpinned tag
        ("${c.image.repository}${lib.optionalString (c.image.tag != null) ":${c.image.tag}"}") by
        explicit choice (allowFloatingTag = true). The registry can move these bits under this
        host at any time with no corresponding change in this Nix config -- drift, accepted
        knowingly. Pin `image.digest` to close this warning.
      '')
      cfg);
  };
}
