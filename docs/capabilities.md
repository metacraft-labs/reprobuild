# Reprobuild Capabilities

`repro capabilities` is the build-system-neutral capability query for tools
that generate Reprobuild provider graphs.

The command prints JSON by default:

```sh
repro capabilities
```

The document is an inspection/API surface, not an on-disk source of truth. It
advertises the installed `repro` binary's provider graph features, execution
features, and HCR support profiles.

Build-system generators should use this query during generation instead of
probing CMake-specific or generator-specific command names. For HCR, external
generators may annotate candidate targets and static source/object/link
relationships, but Reprobuild remains the authority for which actions rebuilt,
which outputs changed, and whether a target should be reloaded, restarted, or
rejected.

Human-readable output is available for diagnostics:

```sh
repro capabilities --format=text
```
