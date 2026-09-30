# Bootstrap Build Graph

`repro build` has two execution layers:

1. Bootstrap work that discovers and lowers the project build graph.
2. The selected project graph executed by the build engine.

The project graph already overlaps invalidation checks and execution: as soon as
an action's dependencies are settled and its own cache/invalidation decision is
"run", the scheduler may launch it while other ready actions are still being
checked. There is no intended "finish all checks, then execute" barrier inside
the project scheduler.

The remaining latency comes from bootstrap work that currently happens before
the project scheduler can start. These phases must also become build graph
edges, with the same dependency-capture and cache semantics as ordinary build
actions:

| Phase | Output artifact | Required dependency evidence |
| --- | --- | --- |
| Project interface extraction | `project-interface.rbsz`; optional `project-interface.nim` stub for callers that import the interface from Nim | Project `reprobuild.nim`, all Nim files imported while registering the DSL, Reprobuild DSL/runtime libraries, Nim compiler identity, compile flags, relevant environment |
| Tool identity resolution | `*-tool-identities.rbtp`, inspection JSON | Project interface, tool provisioning mode, tool catalog entries, pinned package metadata, local PATH profile when in path mode, Nix/tarball/Scoop resolver inputs, realized executable/profile paths |
| Provider compilation | provider binary, `provider-compile.rbsz` | Project interface, provider source files, Reprobuild provider/runtime libraries, Nim compiler identity, compile flags, link inputs |
| Provider graph refresh | `provider-fragments.rbsz` | Provider binary/artifact identity, root entry point, root arguments, provider manifest, directory enumerations, provider evaluation file reads, environment read by provider execution |
| Graph lowering | lowered graph binary | Provider graph snapshot, tool identity artifact, selected target/default target metadata, lowering algorithm version, host path semantics only when they affect the lowered argv/env |
| Dev-shell/direnv environment synthesis | binary environment plan plus shell fragments | Project interface, tool identity artifact, selected dev-env entry point, host/shell selector, environment variables that influence shell generation |

Do not add bootstrap caches that are validated only by hand-written metadata
keys. A bootstrap cache is valid only when it is backed by one of:

- declared inputs that fully describe the phase, or
- automatic monitoring evidence from executing the phase, or
- a native dependency file produced by the tool that ran the phase.

The bootstrap graph should use the same action-cache record format and the same
evidence model as ordinary project actions. A cache hit must be explainable by
the build report and `why`/introspection commands. Cache misses must report a
specific reason such as `input-changed`, `missing-output`, `tool-identity-drift`,
`provider-evaluation-input-changed`, or `directory-membership-changed`.

## Bootstrap Compilers

Before any recipe is compiled, `repro` provisions the Nim compiler and the C
compiler that compile it (`ensureBootstrapToolchainEnv`). It does so in every
tool-provisioning mode, `path` included: the mode says how a recipe's `uses:`
tools resolve, and the recipe has not been read yet. It never searches `PATH`
for them (Distribution-And-Packaging M5, rule 2). The route depends on the
host:

| Host | Nim | C compiler |
| ---- | --- | ---------- |
| Windows | official `nim-2.2.10_x64.zip` | pinned winlibs gcc 16.1.0 archive |
| macOS arm64 / x86_64 | official `nim-2.2.10-macosx_{arm64,x64}.tar.xz` | Xcode Command Line Tools clang (`xcrun -f clang`, SDK from `xcrun --show-sdk-path`) |
| Linux with Nix | pinned nixpkgs `nim` | pinned nixpkgs `gcc` |
| Linux without Nix, other POSIX | official source archive `nim-2.2.10.tar.xz`, built once into the tool store with the C compiler | the system compiler at `/usr/bin/cc`, `/usr/bin/gcc` or `/usr/bin/clang` |

Every archive is pinned by URL and sha256. On macOS the platform's own clang is
the C compiler because the SDK's headers and frameworks are written for it (a
nixpkgs gcc cannot reach them), and because the real clang under the developer
directory is outside SIP and carries no hardened runtime, so the monitor
follows it.

Linux does not use the upstream Linux binary archive: its `bin/nim` is
statically linked, which the preload monitor cannot instrument, so interface
extraction would produce incomplete dependency evidence and never be cached.
Building the same release from its C sources gives a dynamically linked
compiler that the monitor observes.

**A provisioning failure stops the command.** The diagnostic names what was
being provisioned, the route, the tool store, the failure, and the remedy. It
does not fall back to a `nim` or `gcc` on `PATH`.

The sanctioned way to supply the toolchain yourself is explicit:
`REPRO_NIM_COMPILER` (an absolute path, or a bare `nim` to use the one on
`PATH` on purpose) and `REPRO_BOOTSTRAP_CC` (an absolute path; it is probed,
and an unusable one is refused by name). The installed packages and the flake
set `REPRO_NIM_COMPILER` to the Nim they ship. These overrides do not waive
monitoring: a compiler that cannot be monitored still cannot produce a
normally cacheable interface extraction. Windows also raises the stack reserve
of its provisioned `nim.exe`.

## Streaming

Once bootstrap phases are represented as actions, progress can start at process
entry and remain continuous:

1. Run/check bootstrap actions.
2. Load the binary lowered graph as soon as it is up to date.
3. Enter the project scheduler.
4. Launch project actions while remaining project actions are still being
checked.

This keeps execution overlap inside the project scheduler and also makes the
pre-scheduler work visible and cacheable.

## Current Partial Implementations

The codebase already has pieces of this model:

- Interface extraction is a monitored build action. The engine validates its
  observed input closure before reusing `project-interface.rbsz` and its stub.
  The child does not override that decision with a narrower import-walk cache.
- Tool identity resolution has a cache keyed by interface/tool metadata. Nix
  provisioning also has a lower-level materialization receipt cache under the
  unified tool store: the first stage computes the effective Nix package plan,
  and each package plan stores a reusable receipt containing the realized
  `/nix/store` paths, selected executable, unified-store pointer, and probe
  results. This lets another project or a changed project interface reuse the
  same package materialization without invoking `nix build` again. These caches
  are still not recorded as ordinary action-cache entries with monitored
  dependency evidence.
- Provider compilation is already represented as a build action.
- Provider graph refresh stores a binary snapshot and tracks provider
  evaluation file reads and directory enumerations. The CLI can reuse this
  snapshot after validating those recorded inputs instead of invoking the
  provider again, but the refresh itself is not yet an action-cache entry.
- Lowered graph caching stores the lowered action graph as a binary artifact
  keyed by the interface fingerprint, tool identity, provider artifact,
  provider snapshot digest, lowering algorithm version, and PATH profile when
  relevant.

Future optimization work should converge these partial caches into the bootstrap
graph rather than adding more ad hoc fast paths.
