# Runtime library dependencies

A dependency should be described semantically — "this package provides a shared
library", "this executable loads it at runtime" — and the engine should decide
what platform-specific thing must happen so the loader finds it. Today that
decision is instead re-made, differently, in five places.

This document records what the specs already define, what is already
implemented, and the precise gap between them.

## The model is already specified

`Glossary.md` — **execution profile**: "A package-owned description of how an
installed program should be executed", which "may specify … **runtime library
binding rules**". **Launch plan**: the materialized artifact derived from it,
carrying "**runtime library directories**" and a "projected runtime image".

`Launch-Plans-And-Platform-Launchers.md` specifies the `LaunchPlan` record
(including `runtimeLibraryDirs`, `projectedRuntimeImage`, `executionProfile`)
and a per-platform **binding decision algorithm**:

- **Linux** — embedded `RUNPATH` at the realized dependency dirs; else
  `$ORIGIN`-relative `RUNPATH`; else a generated launcher prepending
  `LD_LIBRARY_PATH`, prepend-only and never wider than `runtimeLibraryDirs`.
- **macOS** — `@rpath` with install-name rewriting at realization; else
  `@loader_path`-relative inside a projected image; else a generated launcher
  setting `DYLD_LIBRARY_PATH`, whose presence must be visible in the plan.
- **Windows** — a **generated native launcher** that calls
  `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_USER_DIRS)` and `AddDllDirectory`
  once per `runtimeLibraryDirs` entry; **app-local DLL layout is fallback #2**,
  for binaries that cannot tolerate indirection; projected runtime image is #3.
  "`PATH` mutation is never the primary mechanism."

`Domain-Types.md` even classifies the monitor event: `moLoadLibrary` →
"Runtime tool/library dependency when required".

## Most of the machinery is implemented

- `libs/repro_launch_plan` defines the record and `decideBinding()`.
- `LaunchPlan.runtimeLibraryDirs` exists and is carried through home-profile
  materialization, generations, rollback and prefix remapping.
- The binding kinds exist (`lbkWindowsLauncher`, `lbkMacosScript`, the Linux
  variant) and are selected per host.
- The DSL has a `library <name>:` declaration with `kind: shared|static|both|
  header-only` and `exportedPath:`, parsed into `LibraryDef` and carried on the
  package interface as `libraries: seq[LibraryDef]`.

## The gap

Two links are missing, and they are small and specific.

**1. Nothing populates `runtimeLibraryDirs`.**
`libs/repro_home_apply/src/repro_home_apply/materialize_launchers.nim:86`:

```nim
result.runtimeLibraryDirs = @[]
```

Hardcoded empty. Every launch plan claims no runtime library directories, so
the binding algorithm has nothing to bind and the platform launchers do
nothing — which is why consumers resort to copying DLLs by hand.

**2. There is no consumer-side declaration.**
`uses:` declares a dependency on a *tool* (an executable resolved onto PATH).
There is no way to say "this executable loads library L at runtime". Searching
`repro_project_dsl` for `runtimeLib` / `loadLibrary` returns nothing.

The producer side *is* expressible — `packages/clingo.nim` now declares:

```nim
library clingo:
  kind: shared
  exportedPath: "Library/bin"
```

which is the first use of that declaration anywhere in the tree.

## What the gap costs today

`clingo.dll` alone is arranged for in five hand-written places:

| where | mechanism |
| --- | --- |
| `flake.nix` | `pkgs.clingo` in the devShell |
| `repro_interface_artifacts.runtimeRpathCompilerFlags` | bakes DT_RUNPATH / LC_RPATH |
| `scripts/build_apps.sh` | stages `clingo.dll` beside `repro.exe` |
| `repro_interface_artifacts.stageHostDynlibsBesideBinary` | copies it beside each scratch-compiled helper |
| `repro.nim` Windows staging edge | `findExe` + `fs.copyFile` into `build/bin` |

Each re-derives the same fact. Three of them are on the ambient-execution
baseline (`docs/ambient-execution-linter.md`). All five are the "app-local DLL
layout" strategy — the spec's Windows *fallback #2* — applied because the
primary strategy is unreachable.

## Implementation path

1. **Consumer declaration.** A way for an executable (or package) to state a
   runtime library dependency. The natural spelling parallels `uses:`, e.g. a
   `loads:` block naming packages whose shared libraries must be resolvable at
   run time.
2. **Resolution.** For each declared runtime dependency, resolve the providing
   package's realized prefix and append `prefix / exportedPath` to
   `runtimeLibraryDirs` — replacing the hardcoded `@[]`.
3. **Let the existing binding algorithm act.** No new platform code should be
   needed for the common cases: `decideBinding()` and the launcher kinds are
   already there.
4. **Retire the hand-rolled staging** as each consumer moves over, removing the
   corresponding baseline entries.

### Known wrinkles

- **`exportedPath` is single-valued but the layout is per-platform.** clingo is
  `Library/bin` from conda-forge on Windows and `lib` from nixpkgs on
  Linux/macOS. Either `exportedPath` needs a per-platform form, or it must be
  resolved against the selected provisioning entry rather than the package.
  The declaration added to `packages/clingo.nim` currently states the Windows
  layout only, and is therefore incomplete on POSIX — deliberately, so the
  limitation is visible rather than papered over with a wrong single value.
- **The bootstrap floor still applies.** None of this helps `repro.exe` find
  `clingo.dll` while it is *being built* — the engine cannot prepare an
  execution environment for the binary that runs the engine. Build-time staging
  in `scripts/build_apps.sh` stays. What this replaces is the *runtime*
  arrangement for installed executables and for the helpers reprobuild compiles
  after installation.
