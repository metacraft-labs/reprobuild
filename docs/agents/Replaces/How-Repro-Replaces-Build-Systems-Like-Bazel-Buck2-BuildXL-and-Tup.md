# How Repro Replaces Build Systems (Bazel, Buck2, BuildXL, Tup)

> **Status:** Conceptual mapping guide for developers familiar with monorepo and sandbox build systems.

Reprobuild integrates compilation, caching, and execution under a single native engine, replacing complex monorepo runners.

## Conceptual Mapping

Reprobuild models the workspace as a directed acyclic graph (DAG) of type-checked build targets, combining the correctness of sandboxed engines with the performance of shared-memory caches.

| Modern Build System Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **Starlark / BUILD files** (Bazel/Buck2) | Project DSL (`repro.nim`) | Declarative, statically type-checked rules written in standard Nim. |
| **Sandboxed Execution** (Bazel) | Environment Activation | Merges locked, isolated tool paths into active subprocess execution blocks. |
| **OS-Level Interception / Sandbox** (BuildXL/Tup) | Filesystem Shim | Preloads `librepro_monitor_shim` in user-space to snoop read/write syscalls without kernel drivers. Mismatched/undeclared inputs trigger build errors. |
| **Action Cache** (Buck2) | Shared Memory Cache Daemon | `repro-cache-daemon` provides sub-millisecond local caching. |
| **Remote Build Execution** (Bazel RBE) | Binary Caches | Secure HTTP/TLS publishing and substitution via `repro-binary-cache`. |

## Key Commands

- `repro build [target]` — compile and materialize build targets.
- `repro test [target]` — execute tests with dynamic dependency rebuilding.
- `repro develop` — toggle develop mode to resolve dependencies to local checkouts.
