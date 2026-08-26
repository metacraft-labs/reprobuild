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

### How the dependency record file is published

Each monitored action leaves a record of what it touched at
`<cacheRoot>/monitor-depfiles/<action>.rdep`. It is a debugging surface and a CI
artefact. Whether the build reads it back depends on who ran the monitor: with
the separate monitor process — the default — the file is how an action's record
reaches the build, so it is read once per monitored action; when the build hosts
the monitor itself it already holds the record and never opens the file.

The file appears **atomically**: it is written to a scratch sibling in the same
directory and renamed into place, so a tool watching that directory sees either
no file or a complete one, never a partial write. Nothing else creates or
modifies a `.rdep`.

When the engine hosts the monitor itself, that rename happens **behind the
build** — the action's result is reported and the next actions start before the
file lands, and the build waits for any outstanding ones before it finishes. A
publication that fails (a full disk, a read-only cache root) does not fail the
action, whose result never depended on the file; it means the action's cache
entry is not published, so the next build re-runs that action instead of
reusing it. You will see this as an action that keeps re-executing, with the
reason recorded on its result.

Files named `.<action>.rdep.flush-*` in that directory are scratch. A build
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

## Shell Wrappers

If a recipe uses `sh -c "tool ..."` then the action is associated with `sh`, not
with `tool`. Tool-specific CLI metadata, including ignored input prefixes,
cannot be inferred reliably through that wrapper. Prefer adding or extending a
typed package CLI definition and calling that command directly from the recipe.
