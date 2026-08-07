# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If something
turns out to matter, distill the finding into [`../studies/`](../studies/README.md) and let the
experiment stay disposable.

This is also the open-questions ledger for nixpods's own judgment calls. Every entry below is a
design choice that is *reasoned*, not yet *measured* -- recorded here so the difference stays
visible. Results feed back into `modules/*.nix` and `lib/*.nix` as they close.

All open; nothing has been run yet.

## 001 -- is the generator's own exit code ever a false negative, not just a false positive?

**Question:** this session's empirical testing (see the repo README and lib/build.nix's header)
found several malformed-input shapes where the podman quadlet generator itself exits non-zero
AND produces no `.service` file -- a case `pkgs.runCommand`'s own `set -e` would already have
caught even without lib/build.nix's explicit presence-check loop. What was NOT found this
session: a concrete input that makes the generator exit ZERO while still silently omitting one
specific requested `.service` file (multiple units per run, only one malformed) -- the shape the
presence-check loop is explicitly written to guard against.

**Reasoning as it stands:** keep the presence-check loop regardless. It is cheap, it is what
mirkolenz/quadlet-nix's own `mkQuadletUnitPackage` does, and "no counter-example found yet" is not
"cannot happen" -- systemd's own generator contract (systemd.generator(5)) explicitly permits a
generator to log-and-skip without a non-zero exit, precisely because a generator is forbidden
from aborting the boot it runs during. Relying on the exit code alone would be betting against a
documented contract, not just an untested one.

**What would settle it:** a wider fuzz of malformed `.container`/`.pod`/`.network`/`.volume`
inputs against several podman versions, specifically hunting for an exit-0-but-partial-output
case. Until one turns up (or is found in podman's own test suite / issue tracker), this stays
reasoned rather than measured.

## 002 -- should `rootless.uid` also validate against `users.users.*` more strictly?

**Question:** `modules/nixos.nix`'s linger check is a `warnings` entry, not an `assertions`
failure -- see its own comment for why (lingering can legitimately be managed imperatively,
outside this Nix config, via `loginctl enable-linger`, which nixpods cannot observe).

**Reasoning as it stands:** a hard assertion here would be a real false-positive risk on a
correctly-configured host, and this repo's own principle is "no batch deletions"-adjacent for
config: never fail a build over something that might be fine. A warning, findable by name, is
the honest middle ground.

**What would settle it:** an actual host runs this module with a rootless container, and either
confirms the warning correctly flagged a real gap, or confirms it false-positived against a
working imperative-linger setup. Until one of those happens, this stays a judgment call.

## 003 -- is four kinds (containers/pods/networks/volumes) the right cut, or should `.build`/
`.image`/`.kube`/`.artifact` quadlet kinds get their own modules too?

**Question:** upstream Quadlet also defines `.build`, `.image`, `.kube`, and `.artifact` unit
kinds (see podman-systemd.unit(5)). nixpods implements none of them.

**Reasoning as it stands:** the four implemented here (container/pod/network/volume) cover
"run a pinned image, optionally grouped into a pod, on a network, with a volume" -- the actual
shape of a single-host service. `.build` (build an image from a Containerfile at activation time)
is in tension with THE thesis of this repo (a pinned digest, not a build recipe, is what
"doesn't drift" means); `.kube` (apply a Kubernetes YAML manifest via podman) duplicates k3s's own
job on the same host, which is exactly the boundary the README draws against k3s; `.artifact` is
niche (OCI artifacts that are not container images). None of the three looked like they belonged
in a v1 policy layer.

**What would settle it:** a real host with a real reason to want one of these -- particularly
`.image` (a plain "pre-pull and pin this image with no container using it yet" unit), which is
the most plausible of the three to eventually earn a `nixpods.images.<name>` module using the
exact same `image.{repository,tag,digest,allowFloatingTag}` submodule containers already have.

## 004 -- is the MAJOR version the right granularity for the generator/runtime skew check?

**Question:** `nixpods.podman.requireMatchingMajor` refuses a deploy when the podman that generated
a host's units and the podman that will run them differ in major version. Major is a proxy for the
thing actually at stake, which is whether any flag the generator wrote has moved. Two podman
minors can also disagree about a flag; two majors very often do not.

**Reasoning as it stands:** major is the granularity upstream's own compatibility promise is made
at, so it is the only line that can be drawn without this repo inventing a compatibility table it
would then have to maintain per podman release. Requiring an exact version match instead would fail
every deploy on a host whose distro is one patch ahead of nixpkgs, which is nearly all of them --
a check that fires constantly is a check that gets turned off.

**What would settle it:** an actual instance of a flag that moved between two podman versions
sharing a major, found in podman's own changelog or by a host hitting it. That would turn this from
a proxy into a real comparison -- most likely by diffing the generated `ExecStart=` produced by two
podman packages against the same input, which is a check this repo could run at BUILD time and does
not yet.

**Live starting point:** nixpkgs-unstable ships podman 5.8.4; the Arch host this repo deploys to
ships 6.0.2. The check currently refuses that pairing, which is the correct outcome and also means
the first real deployment has to resolve it rather than discover it. See `docs/gotchas.md`.
