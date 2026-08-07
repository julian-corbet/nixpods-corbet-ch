# docs/gotchas.md

Mechanism-level findings, verified empirically against a real podman/systemd install before this
repo's first commit -- recorded so none of them get rediscovered the hard way. See the main
[README](../README.md) for the design these findings justify.

## The generator really is just an offline INI-to-unit translator

```
$ find $(nix build --print-out-paths nixpkgs#podman)/lib/systemd -iname '*generator*'
.../lib/systemd/system-generators/podman-system-generator
.../lib/systemd/user-generators/podman-user-generator
```

Both are plain symlinks to the same `quadlet` binary. Feeding it a `.container` file with a
digest-pinned `Image=` through `QUADLET_UNIT_DIRS`, with no root, no running podman daemon, and no
network reachable, produced a real unit:

```
[Unit]
Wants=network-online.target
After=network-online.target
Description=demo container
SourcePath=/tmp/.../demo.container
RequiresMountsFor=%t/containers

[Service]
Restart=on-failure
Type=notify
NotifyAccess=all
ExecStart=/nix/store/.../bin/podman run --name systemd-demo --replace --rm --cgroups=split \
  --sdnotify=conmon -d docker.io/library/nginx@sha256:0000...

[Install]
WantedBy=multi-user.target
```

`systemd-analyze verify` on that unit exited `0` with no output -- clean, on the first try, no
extra flags.

## `Pod=` resolves to a literal `BindsTo=`/`After=` pair at generation time, not a runtime lookup

A container with `Pod=demopod.pod` generated:

```
[Unit]
...
BindsTo=demopod-pod.service
After=demopod-pod.service
```

and the pod's own unit generated the reverse:

```
[Unit]
...
Wants=demo2.service
Before=demo2.service
```

Both are plain text in the generated `.service` files -- nothing about `Pod=` involves a runtime
podman query. This is exactly what makes it safe to inspect with `grep` inside a Nix build
sandbox, which `checks/default.nix`'s `quadlet-generates-real-units` check does for real.

## The generator's own exit code is not a reliable success signal -- by design, not by bug

Systemd's generator contract (`systemd.generator(5)`) forbids a generator from ever aborting the
boot it runs during: it may log a warning and omit exactly the one broken unit while the rest of
the boot proceeds regardless of its own exit code. Feeding the real generator several malformed
`.container` fixtures this session found:

| Input | Generator exit | `.service` produced? |
|---|---|---|
| missing the one required key (`Image=`) | `1` | no |
| an unrecognized key (`ThisKeyDoesNotExist=`) | `1` | no |
| a line with no `=` at all | `1` | no |
| an empty file | `1` | no |
| a syntactically valid but semantically wrong value (`HealthRetries=notanumber`) | `0` | **yes** (podman never validates that value is numeric at generation time -- it fails later, at container start) |

Every case that returned a non-zero exit ALSO produced no unit -- which a bare `pkgs.runCommand`
invocation would already have caught via its own `set -e`, no extra assertion required. That does
not make `lib/build.nix`'s explicit "every expected `.service` file must exist" loop redundant,
for two reasons: first, the systemd generator contract explicitly permits a zero exit alongside a
partially-empty result set (nixpkgs issue #498524 is exactly this shape, at boot rather than at
build time -- a generator-injected dependency going unsatisfied, invisible until something tried
to start), and betting nixpods' own build-time safety net on "no counter-example found yet" would
be betting against a documented contract rather than an untested one (see
`experiments/README.md`'s open question 001). Second, checking file PRESENCE rather than exit code
is what actually produces the useful diagnostic: "the file you expected is missing" names the
thing that broke, "the generator returned 1" does not.

## `systemd.packages` feeds BOTH systemd manager instances, which is the whole rootless story

NixOS's `systemd.packages` option is system-level, but `nixos/lib/systemd-lib.nix`'s own
`generateUnits` function defaults its `packages` argument to that SAME list regardless of whether
it is scanning `lib/systemd/system/` (for the root manager, from `systemd.nix`) or
`lib/systemd/user/` (for a `--user` manager, from `systemd/user.nix`) -- both call sites read
`cfg.packages` where `cfg = config.systemd` (confirmed by reading both files directly, not from
memory). This is the entire reason installing a rootless object's generated unit through
`systemd.packages` works on NixOS at all, independent of whether that same uid's `--user` manager
would ever have run `podman-user-generator` itself correctly.

It is also why rootless still needs care nixpods cannot supply on its own: the target uid's
`--user` manager instance has to exist before anything can start in it, which needs
`users.users.<name>.linger = true` -- a real NixOS option (`nixos/modules/config/users-groups.nix`),
gated behind `users.manageLingering`. nixpods asserts nothing here beyond a by-name warning (see
`modules/nixos.nix`) because user/uid management is out of this repo's scope, the same boundary
`nixvm` draws around bridges it never creates.

## The rootless network-online wait is a live, open nixpkgs footgun

[nixpkgs#498524](https://github.com/NixOS/nixpkgs/issues/498524): Quadlet's implicit
`podman-user-wait-network-online.service` dependency (added so a container that needs to pull an
image waits for the network) can time out for reasons unrelated to any specific container --
observed adding 60+ seconds to every rootless container start. `nixpods.containers.<name>.
waitForNetworkOnline = false` renders `DefaultDependencies=false` in the generated unit's own
`[Quadlet]` section (a real section, distinct from the same-named `[Unit]` key systemd itself
defines) to opt a specific container out of this dependency entirely.


## `systemd.packages` means the same thing on system-manager -- which is why one declaration serves both planes

Read out of `numtide/system-manager`'s own `nix/modules/systemd.nix`, not assumed by analogy with
NixOS. Its `/etc/systemd/system` builder is literally:

```
for package in $packages
do
  for hook in $package/lib/systemd/system/*
  do
    ln -s $hook $out/
  done
done
```

followed by the same collision rule NixOS's `overrideStrategy = "asDropin"` produces -- if a unit
of that name already came from a package, the Nix-side definition is installed as
`$out/<unit>.d/overrides.conf` rather than replacing it. `systemd.tmpfiles.rules` is there too,
with NixOS's own syntax. So a package of generated `.service` files, plus a drop-in carrying
`wantedBy`, installs identically on both planes; nothing in nixpods' mechanism needed a per-plane
translation table.

Two things genuinely do NOT cross:

- **There is no `systemd/user` tree.** That etc builder emits `systemd/system` and nothing else,
  so a rootless object would be generated correctly and installed nowhere. `modules/system-manager.nix`
  refuses it by name instead.
- **`virtualisation.*` does not exist.** Podman on a foreign distro is the distro's package, which
  is what `nixpods.podman.path` and the pre-activation assertions around it are for.

## `wantedBy = [ "multi-user.target" ]` does not land in `multi-user.target.wants` on system-manager

One more thing that crosses, but not unchanged. From the same `nix/modules/systemd.nix`:

```nix
substituteTarget = target:
  if target == "multi-user.target" || target == "timers.target"
  then "system-manager.target"
  else target;
```

...applied when it emits the enable symlink:

```sh
mkdir -p $out/'${substituteTarget target}.wants'
ln -sfn '../${name}' $out/'${substituteTarget target}.wants'/
```

So `wantedBy = [ "multi-user.target" ]` -- the default for a container and a pod here -- is the
correct spelling on both planes and produces a symlink in a differently-named directory on each.
On a system-manager host the enable link is at
`/etc/systemd/system/system-manager.target.wants/<name>.service`, and it will not be found by
looking in `multi-user.target.wants/`. (`system-manager.target` is itself `wantedBy =
[ "default.target" ]`, so the unit still comes up at boot; only the location of the link differs.)

Nothing in nixpods needed changing for this -- it is recorded because a host debugging "did my
container actually get enabled" on that plane will otherwise look in the wrong directory first.

## The generated `ExecStart=` binary is redirectable with one environment variable

The generator names the podman that ran it, by absolute store path. It also reads `PODMAN`:

```
$ QUADLET_UNIT_DIRS=./in podman-system-generator ./out1
ExecStart=/nix/store/...-podman-5.8.4/bin/podman run --name systemd-%N ...

$ QUADLET_UNIT_DIRS=./in PODMAN=/usr/bin/podman podman-system-generator ./out2
ExecStart=/usr/bin/podman run --name systemd-%N ...
```

Byte-identical output apart from the three `Exec*=` lines (`ExecStart`, `ExecStop`,
`ExecStopPost`). This is what lets a foreign-distro host generate its units from a nix-built
podman at build time and still run the distro's own podman at run time, instead of carrying a
second copy of the CLI over one shared `/var/lib/containers`. The FLAGS in that ExecStart are
still the generating podman's vocabulary, so the two want to stay on the same major version.

## ...and on a real foreign-distro host, they are NOT on the same major version

That last sentence was advice for as long as nothing checked it. What the two versions actually
are, on the host this repo is deployed to:

```
$ nix eval --raw --impure --expr '(import <pinned nixpkgs> {}).podman.version'
5.8.4

$ pacman -Q podman
podman 6.0.2-3.1
```

So a deploy would generate an `ExecStart=` in podman 5.8.4's flag vocabulary and hand it to podman
6.0.2 to execute. That is exactly the "silently did less than we asked" shape this repo exists to
catch, arriving at container-start time on the host after a build that succeeded.

`nixpods.podman.requireMatchingMajor` (default `true`) closes it, in the only place it can be
closed: the target's own podman version is not knowable at build time any more than its existence
is, so this rides the same system-manager pre-activation hook as the `-x` check. The comparison is
POSIX sh built-ins only -- no awk, no sed, no grep, none of which this config may assume on a
foreign distro:

```sh
running_raw=$("/usr/bin/podman" --version 2>/dev/null || true)
running_version=${running_raw##* }
running_major=${running_version%%.*}
```

`podman --version` prints `podman version 6.0.2`; the format string is `%s version %s`, read out of
the podman binary rather than remembered. All four branches were exercised against `/bin/sh` with a
stub standing in for podman:

| stub prints | result |
|---|---|
| `podman version 6.0.2` (generator on 5.x) | full diagnostic naming both versions, `exit 1` |
| `podman version 5.8.4` | silent, `exit 0` |
| something with no version in it | reports that it could not parse, `exit 0` -- a deploy must not fail because a diagnostic changed shape |
| nothing (binary exits 3) | same "could not read a version" branch, `exit 0` |

Setting `requireMatchingMajor = false` drops the `exit 1` and keeps every line of the report, which
is the same shape `allowFloatingTag` has: a host that took the shortcut is never quietly
indistinguishable from one that did not.

## `Type=oneshot` is a real translation change, not a relabelling -- and `Type=` is the one `[Service]` key quadlet validates

Quadlet copies unknown `[Service]` keys through verbatim (`X-RestartIfChanged=false` lands in the
generated unit untouched), but it reads `Type=` itself:

| `[Service] Type=` in the `.container` | generator | result |
|---|---|---|
| absent | exit `0` | `Type=notify`, `NotifyAccess=all`, ExecStart gains `--sdnotify=conmon -d` |
| `oneshot` | exit `0` | `Type=oneshot`, no notify keys, ExecStart has **no** `-d` and no `--sdnotify` |
| `simple` | exit `1`, no unit | `invalid service Type 'simple'` |

So `oneshot` is what makes `systemctl start <name>` block until the container is done and report
its exit status, rather than returning as soon as conmon says the container is up. For a job
someone starts by hand -- rip this disc -- that difference is the whole interface.

`Privileged=` is NOT a `[Container]` key, in either shape:

```
$ QUADLET_UNIT_DIRS=./in4 podman-system-generator ./out4
quadlet-generator: converting "priv.container": unsupported key 'Privileged' in group 'Container'
exit=1
```

`PodmanArgs=--privileged` is the supported route, and lands verbatim in the ExecStart.

## systemd's `Restart=` is not Podman's, and it does not tell you when you get that wrong

`unless-stopped` is a real Docker/Podman restart policy and not a systemd one. systemd does not
refuse it -- it *ignores* it:

```
$ systemd-analyze verify a-unless-stopped.service
a-unless-stopped.service:6: Failed to parse Restart=unless-stopped, ignoring: Invalid argument
```

The unit loads, with `Restart=no`. A service asking to be kept alive quietly never is. `nixpods`'
`restart.policy` enum therefore carries systemd's seven values and not Podman's vocabulary; since
quadlet passes `[Service]` keys through unvalidated, the Nix type is the only place that check
can happen at all.

`Type=oneshot` narrows the same list further. All seven, against `systemd-analyze verify`
(systemd 261):

| `Restart=` with `Type=oneshot` | result |
|---|---|
| `no`, `on-failure`, `on-abnormal`, `on-abort`, `on-watchdog` | clean |
| `always`, `on-success` | `Service has Restart= set to either always or on-success, which isn't allowed for Type=oneshot services. Refusing.` |

"Refusing" means the unit does not load at all -- discovered on the host, at start time, with a
build that succeeded. `modules/containers.nix` asserts against the accepted list instead.

## A deploy can start an on-demand unit, unless the unit says otherwise

system-manager's activator (`crates/system-manager-engine/src/activate/services.rs`) collects
every unit whose store path changed and calls `ReloadOrRestartUnit` on it. It does not first ask
whether the unit is running, and systemd's `reload-or-restart` job type STARTS an inactive unit.
For an on-demand unit -- `wantedBy = [ ]`, started by hand when the hardware is actually there --
that turns "I changed an unrelated option and redeployed" into "the job ran".

The escape is the same key on both planes, and both activators read it out of the `[Service]`
section specifically:

- system-manager: `parse_systemd_bool(unit_info.as_ref(), "Service", "X-RestartIfChanged", true)`
- NixOS's switch-to-configuration-ng: `parse_systemd_bool(new_unit_info, "Service", "X-RestartIfChanged", true)`,
  and its `parse_unit` merges `<unit>.d/*.conf` drop-ins before looking

nixpkgs' own `serviceToUnit` emits `X-RestartIfChanged=false` into `[Service]` when
`restartIfChanged = false` -- so setting it on the drop-in nixpods already installs for
`wantedBy` covers both. `nixpods.containers.<name>.restartIfChanged` is that option.
