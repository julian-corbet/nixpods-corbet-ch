# nixpods

**Podman Quadlet as a BUILD-TIME translator, never a boot-time generator -- typed Nix options for
digest-pinned containers, pods, networks and volumes, rendered to real systemd units inside the
Nix build sandbox.**

## The problem this repo exists to fix

Plain Quadlet places `.container`/`.pod`/`.network`/`.volume` INI files in
`/etc/containers/systemd/` and lets podman's own systemd **generator** turn them into real units
at every boot. On NixOS that is the wrong layer for it to happen in:

- `nixos-rebuild build` cannot validate a quadlet file -- it is not Nix, and nothing in the
  NixOS module system ever looks at it.
- Systemd generators are contractually forbidden from aborting the boot they run during
  (`systemd.generator(5)`): a malformed quadlet can make the generator log a warning and simply
  emit **no unit at all**, and the rest of the boot proceeds regardless. The first anyone hears
  about it is `systemctl start some-name.service` answering "Unit some-name.service not found" --
  at 3am, not at build time. [nixpkgs#498524](https://github.com/NixOS/nixpkgs/issues/498524) is
  a live, current example of exactly this shape: a quadlet-injected dependency went unsatisfied
  and hung boots for 60+ seconds, invisible until it was already happening.
- There is no `systemd.services.<name>` entry anywhere in `config` for a plain quadlet unit --
  nothing to write an assertion against, nothing `nix flake check` can see.

nixpods' answer: run the exact same generator **inside the Nix build sandbox**, at build time, and
install the result as ordinary NixOS-managed units. If the input is bad, the BUILD fails, by name,
before anything ever reaches a running host. That's it -- that's the entire mechanism. Everything
else in this repo is the policy layer built on top of it.

## The mechanism

podman's `quadlet` binary IS the systemd generator (`podman-system-generator` /
`podman-user-generator` are plain symlinks to it). Verified this session, empirically, on a real
build host:

- It is a pure, offline INI-to-unit translator: no root, no running podman daemon, no network
  reachable. It reads exactly one environment variable, `QUADLET_UNIT_DIRS`, for its input.
- A digest-pinned `.container` renders a real unit with `Type=notify`, `NotifyAccess=all`, and a
  literal `ExecStart=/nix/store/.../bin/podman run ...` line.
- `Pod=some.pod` resolves to a literal `BindsTo=some-pod.service` / `After=some-pod.service` pair
  in the container's own `[Unit]` section at generation time -- not a runtime lookup.
- The generated unit passed `systemd-analyze verify` clean, no extra flags.
- Malformed input (an unrecognized key, a line with no `=`, an empty file, a missing required
  key) reliably makes the generator itself exit non-zero and emit no `.service` file at all.

See [`docs/gotchas.md`](docs/gotchas.md) for the full transcripts, including the one case
(`HealthRetries=notanumber`) where the generator happily emits a unit that will only fail at
container-start time -- outside what generation-time checking can catch, and not what this repo
claims to catch.

`lib/build.nix::mkQuadletUnitPackage` is the ~90-line function that does this: `pkgs.runCommand`
with `QUADLET_UNIT_DIRS` pointed at a `symlinkJoin` of the rendered `.container`/`.pod`/
`.network`/`.volume` files, then it runs the real generator binary, then it **asserts every
expected `.service` file was actually emitted** before letting the build succeed. That last step
is load-bearing, not defensive boilerplate: systemd's own generator contract explicitly permits a
generator to log-and-skip a broken unit without a non-zero exit, so checking presence rather than
trusting the exit code is what turns "the generator silently did less than we asked" into a build
failure instead of an unexplained gap discovered later.

This function is a **vendored** re-implementation of
[mirkolenz/quadlet-nix](https://github.com/mirkolenz/quadlet-nix)'s `lib.nix::mkQuadletUnitPackage`
(MIT-licensed) -- read there first for the upstream shape this was built from; the credit comment
lives at the top of `lib/build.nix` itself. It is not a flake input: at the time this repo was
written, that project was an 8-star repo created the same year with no production use outside its
own test suite, and this exact technique is core mechanism for nixpods, not a dependency this repo
should be one `flake.lock` bump away from losing control of. Everything downstream of this one
function -- the option surface, the digest-pinning rules, the root/rootless default, the health
and restart conventions -- is nixpods' own, not vendored from anywhere.

Generated units install via NixOS's own `systemd.packages`, with `overrideStrategy = "asDropin"`
used for the Nix-side `wantedBy` wiring -- units carry no `[Install]` section of their own; NixOS
activates them the same way it activates any other unit it manages.

## The policy layer -- what actually earns this repo

The generator wrapper above is table stakes; the reason to reach for nixpods instead of a
directory of hand-written `.container` files is these three decisions, made once and enforced
consistently, instead of re-litigated (or forgotten) per service.

### 1. Image pinning by digest

An unpinned `:latest` (or any bare tag) is the exact drift that declarative configuration
management exists to prevent: without a digest, Podman resolves the tag at PULL time, so the
bits actually running on a host are whatever the registry currently happens to serve under that
name -- indistinguishable, from this Nix config's own perspective, from "nothing changed".

```nix
nixpods.containers.web.image = {
  repository = "example.org/app";   # required, no default
  tag = "1.4.2";                    # optional -- human/changelog label ONLY, never authoritative
  digest = "sha256:...";            # THE thing that actually pins the pull
};
```

`tag` and `digest` are separate fields on purpose: `digest` is what actually resolves the image
(Renovate-style tools can target it narrowly), `tag` stays purely for human/diff legibility. Omit
`digest` with `allowFloatingTag` left at its default `false` and the build **fails, by name**,
naming the exact container and the exact reason. Set `allowFloatingTag = true` and it builds, but
with a `warnings` entry naming that container every single time -- a host that took the shortcut
is never quietly indistinguishable from one that pinned properly. There is deliberately no
`AutoUpdate=registry` knob anywhere in this repo: podman polling a registry and swapping a running
container's image with no corresponding Nix config change is precisely the drift nixpods exists
to prevent. The only accepted update path is: bump `digest`, `nixos-rebuild switch`.

### 2. Rootful by default -- one decided default, not per-service guesswork

`nixpods.containers.<name>.rootless.uid` is `null` (rootful, the system-wide manager) unless set.
This is the considered default, not a placeholder, for one concrete and verified reason: NixOS
does not reliably run a per-user (`--user`) systemd generator the way a stock rootless-podman
setup on another distro assumes -- a nixpkgs maintainer's own words: user-generator support "is
just clearly not extended to user generators" on NixOS. A rootless-podman-quadlet setup that
depends on `systemd --user` invoking `podman-user-generator` at session start is standing on
ground NixOS does not reliably provide.

Build-time synthesis sidesteps this completely, root or rootless alike, because nixpods never
depends on either generator running live: it always runs the SAME generator itself, at build
time, and installs the result through `systemd.packages` -- which is system-level, but not
system-manager-only. `nixos/lib/systemd-lib.nix`'s own `generateUnits` function defaults its
`packages` argument to that exact same list regardless of whether it is scanning a package's
`lib/systemd/system/` (root manager) or `lib/systemd/user/` (a `--user` manager) subtree -- read
directly from nixpkgs, not assumed. That is the entire mechanism that lets a rootless object's
generated unit reach `/etc/systemd/user` on NixOS at all.

Sidestepping the generator does not sidestep everything rootless podman needs, which is why the
default stays rootful until a workload has an actual reason to opt in:

- the target uid's `--user` manager instance needs `users.users.<name>.linger = true` to exist
  unprompted at boot -- nixpods warns by name when it can't confirm this, but does not manage
  user accounts itself (out of scope, the same boundary `nixvm` draws around bridges it never
  creates);
- that uid needs its own subuid/subgid range, podman's own concern, not this repo's;
- and the rootless network-online wait is a live, currently-open nixpkgs footgun (see
  [`docs/gotchas.md`](docs/gotchas.md)) that `waitForNetworkOnline = false` exists specifically to
  route around.

### 3. Health and restart conventions, generated rather than retyped

```nix
nixpods.containers.web.health.cmd = "curl -f http://localhost/health";
# interval/timeout/retries/startPeriod all have sane defaults; only `cmd` has none, on purpose --
# a healthcheck nixpods invented on this service's behalf would be a fake signal.

nixpods.containers.web.restart.policy = "on-failure"; # the default; always overridable
```

One typed submodule for restart/backoff (`Restart=`, `RestartSec=`, `StartLimitBurst=`,
`StartLimitIntervalSec=`), shared between containers and pods, instead of every service
hand-copying that four-key boilerplate and drifting (`RestartSec=5` here, `RestartSec=3` there,
for no reason anyone could reconstruct). Health is `null` (no healthcheck) unless a command is
given; every other health field is inert until `cmd` is set, so "I didn't configure a
healthcheck" and "I configured one badly" stay visibly different states.

## Boundaries

**vs. k3s** -- k3s is the default for services on this fleet. nixpods is for workloads that are
single-host **by nature** -- something with real local state, a hardware dependency, or an
identity tied to one specific machine -- not merely for something that happens to be small today.
"It's small" is not a reason to reach for nixpods; "it cannot be anything but this one host" is.

**vs. a VM** -- reach for a VM only when the workload needs a different KERNEL (a different OS
entirely, or kernel-level isolation a container can't give). If the workload runs Linux and needs
process/namespace isolation, that is what a container already is; a VM is heavier machinery for a
question nixpods already answers.

**vs. `virtualisation.oci-containers`** -- the honest comparison, not an overstated one:
`oci-containers` already sets `Type=notify`/`NotifyAccess=all` and has its own typed `sdnotify`
enum (`container`/`conmon`/`healthy`/`ignore`) -- verified directly against
`nixos/modules/virtualisation/oci-containers.nix`; this repo does not reinvent that. What
`oci-containers` genuinely lacks, also verified directly against that same module, is `Pod=`
(no pod-grouping concept at all) and a typed `HealthCmd=`/interval/timeout/retries surface (a
healthcheck there means hand-assembling `--health-cmd=...` into a raw `extraOptions` string
yourself). Reach for nixpods specifically when pod-grouping or a typed healthcheck convention is
what you need; `oci-containers` remains a perfectly reasonable choice for a single standalone
container that needs neither.

## Usage

```nix
{
  inputs.nixpods.url = "github:julian-corbet/nixpods-corbet-ch";

  outputs = { self, nixpkgs, nixpods, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixpods.nixosModules.default
        {
          nixpods.containers.web = {
            image = {
              repository = "example.org/app";
              tag = "1.4.2";
              digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
            };
            ports = [ "8080:80" ];
            volumes = [ "/srv/example/data:/data" ];
            health.cmd = "curl -f http://localhost/health";
          };
        }
      ];
    };
  };
}
```

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules.nixpods` / `.default`, the pure `lib.*`, `checks`, and the deliberately-failing demo `packages` output. |
| `modules/containers.nix` | `nixpods.containers.<name>` -- the main policy-bearing option surface. |
| `modules/pods.nix` / `networks.nix` / `volumes.nix` | The other three Quadlet kinds, deliberately thin. |
| `modules/default.nix` | The wiring: collects every declared object, runs the real generator, installs via `systemd.packages`. |
| `lib/build.nix` | The vendored `mkQuadletUnitPackage` -- see its own header for the full credit and reasoning. |
| `lib/render.nix` | The pure typed-option -> Quadlet-INI translation table. |
| `lib/options.nix` | Option fragments shared by all four kinds (root/rootless, restart, escape hatches). |
| `docs/gotchas.md` | The empirical findings this design is built on -- transcripts, not assertions. |
| `checks/default.nix` | Eval-time + one real-build check; see its own header for the split. |
| `checks/demo-malformed-fails-build.nix` | The negative proof: `nix build .#demo-malformed-container-fails-build` is SUPPOSED to fail. |
| `experiments/` | Open judgment calls, not yet settled -- see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written-up findings that changed a decision -- see [`studies/README.md`](studies/README.md). |

## Status

First cut. The mechanism (`lib/build.nix`) and the full policy layer (image pinning, root/rootless
default, health/restart conventions) are implemented and covered by `nix flake check` -- both the
eval-time assertions (an unpinned image, a dangling `Pod=` reference, a container/pod name
collision, all fail evaluation by name) and one real, non-eval build that runs the actual
generator and greps its output for the exact facts that prove the mechanism (real `ExecStart=`,
`Type=notify`, `NotifyAccess=all`, `Pod=` resolved to a literal `BindsTo=`, the healthcheck flag).
`systemd-analyze verify` was run against this exact mechanism too, empirically, once, live,
outside the Nix build sandbox (which has no writable `/run` for it to use) -- see
[`docs/gotchas.md`](docs/gotchas.md) for that transcript; it is not re-invoked by `nix flake
check` itself, and `checks/default.nix`'s own comment says why. Not yet done, deliberately:
`.build`/`.image`/`.kube`/`.artifact` Quadlet kinds (see `experiments/README.md`'s open question
003 for why, and the most likely next one to actually earn its own module). Nothing here has yet
run a real workload on a live fleet host; that is the next step, not this one.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
