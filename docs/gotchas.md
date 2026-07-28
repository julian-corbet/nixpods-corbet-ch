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
`modules/default.nix`) because user/uid management is out of this repo's scope, the same boundary
`nixvm` draws around bridges it never creates.

## The rootless network-online wait is a live, open nixpkgs footgun

[nixpkgs#498524](https://github.com/NixOS/nixpkgs/issues/498524): Quadlet's implicit
`podman-user-wait-network-online.service` dependency (added so a container that needs to pull an
image waits for the network) can time out for reasons unrelated to any specific container --
observed adding 60+ seconds to every rootless container start. `nixpods.containers.<name>.
waitForNetworkOnline = false` renders `DefaultDependencies=false` in the generated unit's own
`[Quadlet]` section (a real section, distinct from the same-named `[Unit]` key systemd itself
defines) to opt a specific container out of this dependency entirely.
