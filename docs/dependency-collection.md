# Dependency Collection

Reprobuild actions declare their dependency collection policy through the
package CLI definition that produced the action. The build recipe should name a
typed package command, such as `cargo.build(...)`, whenever possible. Shell
wrappers are only for opaque commands that do not yet have a typed CLI surface.

## Automatic Monitoring

`dependencyPolicy automaticMonitor` runs the action under the platform monitor
and records file reads, file writes, path probes, and directory enumerations.
The resulting monitor evidence is used to compute the action cache fingerprint.
Tool implementation files are not project inputs: the engine removes monitored
paths below resolved tool roots because those paths are already represented by
the tool identity.

### Who runs the monitor

By default the engine launches a monitored action through a separate
`repro internal io monitor` process, which hosts the monitor and spawns the
command. The engine can instead host the monitor itself, with the command as
its own direct child and no process in between; this is off by default and is
requested per build.

Hosting in-process removes one process spawn per monitored action, but it moves
the monitor's end-of-action work onto the scheduler's single loop, where it is
paid one action at a time instead of concurrently. Measured on Linux, that
trade is a win only when actions are launched one at a time: at the default
parallelism it costs roughly 2x for very short actions, about 20% for actions
doing ~100 ms of work, and nothing measurable for actions doing ~500 ms or
more. Prefer the default unless you have measured your own workload.

One operational difference is worth knowing before enabling it. Through the
default path, an action's captured `stdout` and `stderr` are bounded in memory
while it runs — output past the limit is read and discarded, so a runaway
action costs no disk. The in-process host redirects the child's output straight
into `<cacheRoot>/actions/` instead, and a redirected file has no such bound: it
is truncated to the limit only once the action finishes. An action that writes
gigabytes therefore writes gigabytes into the cache root before anything
truncates it. If `cacheRoot` is on a small filesystem, that peak is the thing to
watch.

Not every launch path can host. The engine can only be the monitor's host when
the engine is the process that spawns the command, and two of the launch paths
are not: the RunQuota helper path starts the action from a separate helper
process, and the inline RunQuota path spawns it inside RunQuota as part of
binding it to a granted lease. Asking for hosting normally leaves those paths on
the default `repro internal io monitor` path, which monitors them exactly the
same way. Asking for it in the stricter "hosting is required" form instead
**fails** such an action with a diagnostic naming the launch path. That is
deliberate: a hosted command carries no monitor wrapper, so a hosted plan
arriving at a launch site that starts no host would run with nothing watching
it, publish a cache entry against an empty dependency set, and report no error.
The engine refuses that state rather than producing it.

### How the dependency record file is published

Each monitored action leaves a record of what it touched at
`<cacheRoot>/monitor-depfiles/<action>.iomon`. It is a debugging surface and a CI
artefact. Whether the build reads it back depends on who ran the monitor: with
the separate monitor process — the default — the file is how an action's record
reaches the build, so it is read once per monitored action; when the build hosts
the monitor itself it already holds the record and never opens the file.

The file appears **atomically**: it is written to a scratch sibling in the same
directory and renamed into place, so a tool watching that directory sees either
no file or a complete one, never a partial write. Nothing else creates or
modifies a `.iomon`.

When the engine hosts the monitor itself, that rename happens **behind the
build** — the action's result is reported and the next actions start before the
file lands, and the build waits for any outstanding ones before it finishes. A
publication that fails (a full disk, a read-only cache root) does not fail the
action, whose result never depended on the file; it means the action's cache
entry is not published, so the next build re-runs that action instead of
reusing it. You will see this as an action that keeps re-executing, with the
reason recorded on its result.

Files named `.<action>.iomon.flush-*` in that directory are scratch. A build
removes its own; leftovers mean a build was killed mid-flight and they can be
deleted.

Package definitions may declare additional monitored input prefixes that should
not participate in the action cache key:

```nim
package cargo:
  executable cargo:
    cli:
      dependencyPolicy automaticMonitor,
        ignoredInputPrefixes = @[
          "$CARGO_HOME/.global-cache",
          "$CARGO_HOME/.package-cache",
          "$HOME/.cargo/.global-cache",
          "$HOME/.cargo/.package-cache"
        ]
```

These prefixes are part of the CLI metadata. They are copied into the action
payload, lowered into the engine dependency policy, and applied only to
monitor-discovered or dependency-file-discovered inputs. Explicitly declared
inputs are never filtered by this mechanism.

The prefixes support `$VAR` and `${VAR}` expansion using the action environment,
falling back to the process environment. Prefix matching is path-prefix based:
the path equal to the prefix and any child path below that prefix are ignored.

## When To Use Ignored Input Prefixes

Use `ignoredInputPrefixes` for volatile tool-maintained metadata that is read as
part of normal execution but is not a semantic input to the produced artifact.
Examples include Cargo's package/global cache bookkeeping. Do not use it for:

- source trees, generated source files, lock files, or package manifests
- dependency registry source files that affect compilation
- output directories that should instead be declared as outputs
- broad home-directory or cache-directory suppression

The owning package CLI definition is the right place for these entries because
the exception is a property of the tool's runtime behavior. Project recipes
should not repeat this knowledge, and the build engine should not know about
specific tools such as Cargo.

## Trusted IPC Peers (`daemons.conf`)

An action that opens an IPC channel to a process outside its own monitored tree
is graded incomplete, so it never publishes a cache entry and rebuilds on every
run. That is the correct default: the monitor cannot see what the peer did on
the action's behalf, so it cannot claim the record is complete.

A few peers can nevertheless be accounted for, because of what they are:

- `runquotad` grants and releases leases and accepts telemetry rows. It serves
  no file content at all, so an action that talks to it has consumed nothing
  the monitor failed to see.
- the **Nix daemon** and reprobuild's own **store daemon** serve
  content-addressed store paths, whose identity is already in the action key.

`repro` comes to trust such a peer in one of two ways, and they are not equally
strong.

**Derived** — the build started the daemon itself, so its pid is a fact the
build holds rather than a claim anyone made. Nothing is configured and nothing
can be got wrong. This is what happens on a host with no host-wide `runquotad`.

**Declared and checked** — the daemon was already running, so the build has to
be *told* about it and has to *verify* what it was told. Declare it in
`/etc/repro/daemons.conf` (system) or `~/.config/repro/daemons.conf` (per user;
it extends the system file and replaces its entry for a repeated daemon):

```ini
[runquotad]
socket  = /run/runquota/runquotad.sock
program = runquotad
uid     = 0

[nix-daemon]
socket  = /nix/var/nix/daemon-socket/socket
program = nix-daemon
uid     = 0

[repro-store-daemon]
socket = /run/user/1000/reprostore-1000.sock
image  = /nix/store/...-reprobuild/bin/repro
```

Keys:

- `socket` (required) — the absolute path of the daemon's unix socket. An
  endpoint that is not an absolute path is refused: the kernel names no peer
  for a network socket, so a network peer can never be trusted.
- `image` — the executable the peer must be running, compared against
  `/proc/<pid>/exe`. The strongest assertion. It is **refused, not weakened**,
  when that link cannot be read — which is the case for a daemon running as a
  different user — so do not declare `image` for a root-owned daemon.
- `program` — the peer's `comm`. Kernel-recorded and world-readable, but a
  process can set its own, so this narrows accidents rather than attackers.
- `uid` — the peer's *effective* uid as the kernel reports it at connect time.
  Un-forgeable — no userspace end contributes to it — and it is re-checked at
  grading time, because a process can acquire privileges in place (by exec'ing
  a setuid image, or by restoring a saved set-user-ID) without changing its pid
  or its kernel start time.

**`image` or `program` is required**, and a section that asserts only `uid` is
refused. The reason is that the §Class 3 branch — what the daemon contributes —
is a property of the *program*, so a check that identifies no program has not
checked the thing the exemption rests on. Concretely: on a socket-activated
host, the process on the far end of a daemon's socket is `systemd`, and it
answers *every* socket it activates; a `uid = 0` declaration would trust
everything that process serves. Requiring `program` refuses it, because
`systemd` is not `nix-daemon`.

That also means **a socket-activated daemon cannot be declared** until it has
been activated by something else — which is honest: until then, the peer really
is not the daemon. A section naming only a socket is refused for the related
reason: "something is listening at this path" is not a check.

For a root-owned daemon read from an unprivileged `repro`, the shipped shape is
therefore `program` + `uid`. Neither half is redundant: `program` says *what*
the peer is, `uid` is the half nothing in userspace can forge.

What a daemon *contributes* — whether it serves content, and whether that
content is already in the key — is **not** configurable. It is a property of
the program, compiled into `repro` per daemon, which is why the section name
comes from a fixed vocabulary and an unknown name (or an unknown key) is an
error rather than an ignored line.

### What the check establishes, and what it does not

At the start of every build `repro` connects to each declared socket, asks the
kernel for the peer's credentials (`SO_PEERCRED`), and verifies every assertion
the declaration made. The pid it obtains is the same fact the monitor reads at
the action's own connect, and that is what ties the check to the observation.
Each trusted pid is re-validated when an action's evidence is graded — against
the kernel's process start time, and against every assertion that was verified
— so a daemon that has exited, had its pid recycled, exec'd into a different
program, or raised its privileges stops being trusted without anyone having to
notice.

It does **not** establish that the declared program deserves trust; that is
what the fixed vocabulary is for. It does not make a network peer attributable.
And it cannot identify a privileged daemon's executable from an unprivileged
build, which is why `program` (with `uid`) is what is available there.

**It also does not scope the trust to the endpoint that was declared.** What
gets recorded is a *process*: "pid P, running the declared program". The
monitor's exemption is keyed on the peer pid, so if that same process also
serves some other socket, an action that talks to *that* socket is forgiven
too. This is why `image`/`program` is mandatory — it is what makes the recorded
fact a statement about a program rather than about whatever happens to be
listening — and it is why each declarable daemon's entry in the fixed
vocabulary has to be true of *every* channel that program serves, not just of
the one you declared. All three admitted today are: `runquotad` speaks one
lease/telemetry protocol wherever it binds, and the two store daemons serve
content-addressed paths wherever they bind.

Every declaration is reported on every build, passed or failed, so a
declaration for a daemon that has moved or stopped running is visible rather
than silently inert.

## Shell Wrappers

If a recipe uses `sh -c "tool ..."` then the action is associated with `sh`, not
with `tool`. Tool-specific CLI metadata, including ignored input prefixes,
cannot be inferred reliably through that wrapper. Prefer adding or extending a
typed package CLI definition and calling that command directly from the recipe.
