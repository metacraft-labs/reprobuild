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
