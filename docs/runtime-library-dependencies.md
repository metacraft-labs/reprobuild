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

**1. Nothing populates `runtimeLibraryDirs`.** — **CLOSED.**

`materialize_launchers.nim` read `result.runtimeLibraryDirs = @[]` since the
field was introduced, so every launch plan claimed no runtime library
directories, the binding algorithm had nothing to bind, and the platform
launchers did nothing — which is why consumers resorted to copying DLLs by
hand. It is now supplied from the declared model; see "How it fits together"
below.

**2. The consumer-side declaration exists and was unwired.** — **CLOSED.**

An earlier revision of this document said "there is no consumer-side
declaration" and proposed inventing a `loads:` block. **That was wrong, and
acting on it would have produced a second surface duplicating the first.**

`runtimeDeps:` is already the declaration. It is documented in `macros_a.nim` as
carrying "HOST-platform tools/libraries consumers need at runtime or link time",
parses with the same constraint grammar as `uses:` / `buildDeps:`, and lands in
its own `PackageDef.runtimeDeps` slot so it does not leak into `toolUses`.

Measured across the recipe tree:

| | count |
| --- | --- |
| recipes declaring a `runtimeDeps:` block | 286 |
| …whose block is an empty `discard` / TODO stub | 226 |
| …carrying real entries | **60** |

The populated ones say exactly what the model wants — `accountsservice` declares
`"glib2"`, `"polkit"`, `"dbus"`; `audit` declares `"libcap-ng"`.

What is missing is the wiring, not the vocabulary. `runtimeDeps` reaches the
build engine's platform routing (`repro_build_engine/platform.nim` routes it as
`dkRuntime` against the host triple) and stops there. Grepping
`repro_home_apply` and `repro_launch_plan` for `runtimeDeps` returns nothing at
all.

**The producer side is not expressible either.** The DSL's `library <name>:`
block looks like the vehicle and is not:

- `exportedPath` is documented (`types.nim:185`) as "the producer-relative
  directory a Nim library-consumer threads onto its `nim c --path:`" — a Nim
  **source** path, defaulting to `src`. Pointing it at `Library/bin` would tell
  Nim consumers to add a DLL directory to their source path.
- `kind: shared` describes a library the package **builds** (".so / .dylib /
  .dll"), not a shared library that arrives inside a provisioned prefix.

So both ends of the contract need a new declaration surface, not just the
consumer end.

### The `library` body silently ignores what it does not recognise

Worth knowing before extending it. The body loop in `macros_a.nim` ends:

```nim
of "discard": discard
else:          discard      # <- unknown statements are dropped
```

A statement the parser does not recognise is neither applied nor rejected. A
`when defined(windows): exportedPath: "…"` inside the body **compiles cleanly
and sets nothing**.

An earlier revision of this document advised fixing that `else` to error. **That
advice was wrong**: the same body is consumed by more than one pass, so
"`parseLibrary` ignores it" is not the same as "nobody consumes it". Erroring
would have rejected valid, working declarations.

**This is now fixed** — the catch-all warns, after taking the cross-pass
inventory it needed:

| member | consumed by |
| --- | --- |
| `kind`, `exportedPath`, `discard` | `parseLibrary` (`macros_a.nim`) |
| `build` | `emitM4ArtifactBuildLowering`, which re-classifies the body and claims `soM4Build` |
| `cli` | `emitM6CliLowering`, which head-matches `cli` on any M3 artifact body, library included |
| anything else | **nobody** — now warns |

A `when` gets its own message, since it is the case that motivated the work and
`calleeName` returns `""` for it.

### Measure before you claim a blast radius

Two figures in earlier revisions of this document — "41 bodies contain `build:`
blocks", "well over a hundred" — were both wrong, from a `grep -A4` that spilled
into neighbouring lines. An indentation-aware scan of every `library` body in
the tree gives the real distribution:

| member | count |
| --- | --- |
| `discard` | 307 |
| `kind` | 7 |
| `build` | 4 |
| `exportedPath` | 3 |

Nothing else appears at all. All 7 `kind` and 3 `exportedPath` uses are in the
DSL's own test file; only **three real recipes** put a `build:` in a library
body (`boost`, `clingo`, `nss`), and every other real body is a bare `discard`.

Making the catch-all speak immediately surfaced a latent defect: the
`of "discard":` arm was **dead code** and always had been. A bare `discard`
parses as `nnkDiscardStmt`, for which `calleeName` returns `""`, so it had been
falling through to the silent catch-all since M12 — harmlessly, until the
catch-all started warning, at which point it would have warned on 307 of the
321 library-body statements in the tree.

A `when` inside a `library` body still sets nothing — the warning reports the
drop, it does not implement the branch. Supporting it needs the
store-the-body-in-a-template shape below.

**This no longer blocks per-platform layout**, which is what the `when` was
wanted for. The setters take expressions now, so the better route works today:

```nim
import repro_dsl_stdlib/prefix_layout

library clingo:
  kind: shared
  exportedPath: runtimeLibDir(plConda)   # "Library/bin"
```

See "Reusable platform abstractions" below — the vocabulary is implemented in
`repro_dsl_stdlib/prefix_layout`.

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

## How it fits together

The model is wired end to end. Both halves are declarations; the engine joins
them and the existing binding algorithm acts on the result.

```nim
# producer — the package that PROVIDES the library says where it lives,
# because it is the only party that knows its own prefix layout
package clingo:
  runtimeLibrary "clingo", dir = runtimeLibDir(plConda),
    cpu = "x86_64", os = "windows"
  runtimeLibrary "clingo", dir = runtimeLibDir(plUnix), os = "linux"

# consumer — names the dependency, and nothing about its layout
package someTool:
  runtimeDeps:
    "clingo"
```

| stage | where |
| --- | --- |
| producer declaration | `runtimeLibrary` → `PackageDef.runtimeLibraries` |
| consumer declaration | `runtimeDeps:` → `PackageDef.runtimeDeps` |
| host slice selection | `selectRuntimeLibraries(pkg, cpu, os)` |
| the join | `resolveRuntimeLibraryDirs(deps, cpu, os, prefixOf)` |
| population | `materializeLaunchers` → `LaunchPlan.runtimeLibraryDirs` |
| binding | `decideBinding()` — unchanged, it already consumed `dependencyDirs` |

**Which dependencies are libraries** is answered without a heuristic: a
dependency contributes a directory exactly when the package providing it
declares a `runtimeLibrary` matching this host. `runtimeDeps:` carries
"tools/libraries" together, so classifying by name would have been unreliable
and invisible when wrong. A tool declares none and contributes none.

**An unresolved dependency raises.** A package that declares a runtime library
for this host but has no realized prefix is a planner bug, and omitting its
directory would produce a launcher that looks complete and dies at load time
with the "could not load" this whole model exists to prevent.

**One trap worth knowing.** `hostArch()` in the launcher layer reports `arm64`
for the machine the DSL's `cpu = "..."` fields call `aarch64`. Passing it
straight into the matcher makes every `cpu = "aarch64"` declaration match no
host — silently, since a non-matching slice is indistinguishable from an absent
one. The vocabularies are converted in `dslCpuToken`, not conflated.

### What this does *not* do yet

Most `runtimeDeps:` blocks are empty TODO stubs (226 of 286), so populating
directories from this field does nothing for most packages until those are
filled in. That is the correct place for the information, but it means this
change on its own does not fix a given package's runtime loading — the recipe
has to declare the dependency first.

The five hand-rolled `clingo.dll` arrangements below are also still in place.
Retiring them is per-consumer work now that the mechanism exists, not a
prerequisite of it, and the bootstrap floor means at least the build-time
staging stays regardless.

## Implementation path

*(Historical — all four steps are done. Kept because the reasoning about what
was struck and why is still the best summary of the design.)*

Step 1 of the original plan — "invent a consumer declaration" — is struck: the
declaration is `runtimeDeps:`, and inventing a `loads:` block alongside it would
have created two ways to say the same thing.

1. **Carry `runtimeDeps` to the launcher layer.** This is the whole of the
   remaining work, and it is a multi-layer change rather than a wiring
   one-liner. `materializeLaunchers` already receives every realized prefix
   (`realized: seq[RealizedRecord]`), so the destination has what it needs. What
   it lacks is any statement of *which* packages a given launcher's package
   loads at run time: `PlannedLauncher` carries only `commandName` and
   `fromPackageId`, and `RealizedRecord` carries no dependency list. So the
   dependency set has to be threaded from the package model through the planner
   to here.
2. **Resolve to directories.** For each runtime dependency, look up its realized
   record and append `prefixAbsolutePath / runtimeLibDir(<layout>)` to
   `runtimeLibraryDirs`, replacing the hardcoded `@[]` at
   `materialize_launchers.nim:86`. Use the *runtime* library dir, not the link
   one — see the vocabulary note above; on Windows they differ, and this is
   precisely where a naive `lib` would fail to find `clingo.dll`.
3. **Let the existing binding algorithm act.** No new platform code should be
   needed for the common cases: `decideBinding()` and the launcher kinds are
   already there and already consume `dependencyDirs`.
4. **Retire the hand-rolled staging** as each consumer moves over, removing the
   corresponding baseline entries.

### Design questions, and how each was answered

These were recorded as things to settle deliberately rather than discover
mid-implementation. Each is now decided; the answers are the interesting part
of the design:

- **Which entries are libraries?** → Ask the provider. A dependency contributes
  a directory exactly when the providing package declares a `runtimeLibrary`
  for this host. No name-based classification.
- **How does a constraint string map to a package?** → The leading token, the
  same rule `selectorFromConstraint` applies at macro time.
- **What does an unresolvable entry do?** → Raises. Silently omitting is the
  original bug relocated.
- **The empty stubs** → left empty. The mechanism works; the 226 TODO blocks are
  recipe-authoring work, and filling them in is what makes it act.

The original statements of each follow, since the reasoning behind them is why
those answers are the right ones:

- **Which `runtimeDeps` entries are libraries?** The field is documented as
  carrying "tools/libraries". A tool needs `PATH`; a library needs the loader
  search path. Treating every entry as a library would widen the launcher's
  search path beyond what the spec permits ("never wider than
  `runtimeLibraryDirs`").
- **How does a constraint string map to a realized package id?** `"glib2 >=2.70"`
  has to resolve to whatever `RealizedRecord.packageId` the planner produced.
- **What does an unresolvable entry do?** Failing the launcher build is
  defensible; silently omitting the directory is not — that reproduces the
  original bug in a new place.
- **The 226 empty stubs.** Most `runtimeDeps:` blocks are TODO placeholders, so
  populating `runtimeLibraryDirs` from this field alone will do nothing for most
  packages until those are filled in. That is fine — it is the correct place for
  the information — but it means this change will not, on its own, fix a given
  package's runtime loading.

### Expressing per-platform layout

The library directory differs by provisioning source, not merely by OS: clingo
is `Library/bin` from conda-forge on Windows and `lib` from nixpkgs on
Linux/macOS. Two styles should work, and today neither does:

**`when` statements.** These are the obvious smoothing tool, but the DSL bodies
silently drop them (see above).

The wrong way to support them is to teach the macro to *evaluate* the `when` —
to look at the condition, decide which branch is live, and take the value. That
is an evaluator inside a macro, and it can never cover the ways an expression
may legitimately be written. It also fails the same way the current setters do:
by rejecting or ignoring anything it does not recognise.

The right way is a **transformation**: rewrite the DSL body into ordinary Nim
and let the compiler do what it already does. Emit the `when` into the generated
code with its condition untouched, recursing into each branch to turn setters
into assignments:

```nim
# from
library clingo:
  kind: shared
  when defined(windows): exportedPath: "Library/bin"
  else:                  exportedPath: sharedLibDir(plUnix)

# emit
block:
  var lib = LibraryDef(name: "clingo", kind: lkShared)
  when defined(windows): lib.exportedPath = "Library/bin"
  else:                  lib.exportedPath = sharedLibDir(plUnix)
  registerLibrary(lib)
```

The macro never inspects the condition or the value. Nim resolves both.

### The general form: store the body in a template

The verbatim-`repr` trick above fixes one setter's *value*. It does not help
with control flow, because the parser still has one compile-time object to fill
in and a `when` has two branches.

The general fix is to stop parsing the body at all: **emit a template whose body
is the user's body, verbatim** — a template used as a named variable holding AST
— and let each consumption mode instantiate it with its own bindings for the
setter names. Validated end to end:

```nim
# dsl.nim — the macro parses nothing
macro library*(name, body: untyped): untyped =
  let t = ident("libBody_" & name.strVal)
  result = newStmtList()
  result.add(newProc(name = postfix(t, "*"), body = body,
                     procType = nnkTemplateDef))
```

```nim
library foo:
  kind: shared
  when defined(windows): exportedPath: "Library/bin"
  else:                  exportedPath: sharedLibDir(plUnix)

block modeA:                      # collect the declared shape
  template kind(v: untyped) = got.add("kind=" & v)
  template exportedPath(v: untyped) = got.add("exportedPath=" & v)
  libBody_foo()
# -> @["kind=shared", "exportedPath=Library/bin"]

block modeB:                      # same AST, different interpretation
  template kind(v: untyped) = inc n
  template exportedPath(v: untyped) = inc n
  libBody_foo()
# -> setters seen: 2
```

The `when` is resolved by the compiler at instantiation; the macro never sees
it. This is the same shape as the existing mode split (`reproProviderMode` /
`reproInterfaceMode`), which today is done by emitting `when defined(...)`
guards around generated procs rather than by re-instantiating a stored body.

**`library` was the wrong declaration to pilot this on**, and the pilot went to
`service` instead. It is used by **208 recipes carrying 309 declarations** — a
lot of call sites to change meaning under, with no way to validate short of
building every recipe.

The "41 of those bodies contain `build:` blocks" figure that also appeared here
was wrong; the real count is **3 recipes** (see the measured distribution
above). The bodies are overwhelmingly a bare `discard`, which makes the eventual
conversion far less risky than this section originally implied — the risk is
concentrated in the *number* of declarations, not in the variety of what they
contain.

The conversion also ripples further than the parser. `packageLiteral(pkg)`
produces a `PackageDef(...)` **expression**, consumed at three sites
(`macros_b.nim:228`, `:243` via `parseExpr`, `:3542`). Making `libraries:`
runtime-built means emitting a generated proc and referencing it from that
expression, and `parseLibrary` returns a shared `LibraryDef` with nowhere to
stash an unparsed body — so the body AST has to be threaded alongside `pkg`
through to the emitter.

Two constraints found while proving it:

- **The instantiating scope must supply the whole vocabulary**, not just the
  setters. `kind: shared` uses `shared` as a bare identifier, so each mode must
  bind the value idents too. That is arguably the point — a mode defines what
  the vocabulary means — but it has to be designed rather than discovered.
- **Setter names can collide with imported symbols.** `kind` clashed with
  `macros.kind(NimNode)` when `std/macros` was in scope at the instantiation
  site, and overload resolution picked the import. The DSL vocabulary wants its
  own module and careful naming.

### Why the current design forces the evaluator

`macros_a.nim` builds a compile-time `LibraryDef` and then **re-serialises it
back into Nim source text** (`result.add("LibraryDef(name: " & escForCode(...)`).
Because the generated source must contain a literal, the macro has to already
know the value — hence `stringLiteral()` and "requires a string literal". The
evaluator is not an accident of this code; it is what re-serialisation demands.

The same file already contains the correct pattern, for typed outputs: the M1
"reparse" hook stores the user's expression as the `.repr` of the source
`NimNode` and inlines it *verbatim* into the generated source, so the outer
`parseStmt` re-parses it in the call-site scope. Its own comment says "Inline the
user's pathExpr source verbatim". Applying that to the setters — store
`node.repr`, emit it unchanged — removes the literal restriction without any
evaluation, and makes helper calls work for free.

**Reusable platform abstractions — implemented.** Better than scattering `when`
at every declaration: a shared vocabulary of prefix layouts, now in
`repro_dsl_stdlib/prefix_layout`.

```nim
import repro_dsl_stdlib/prefix_layout

library clingo:
  kind: shared
  exportedPath: runtimeLibDir(plConda)   # "Library/bin"
```

The axis is the **provisioning source** (conda-forge vs nixpkgs vs a bare zip),
with the platform only correlating — so the enum names layouts, not operating
systems. `plConda` is not "Windows": conda-forge uses the `Library/` prefix on
win-64 specifically, while its Linux packages are ordinary `bin/`+`lib/`.

The distinction worth knowing about is **loadable vs linkable**. On Unix one
directory holds both. On Windows they differ: the loadable `foo.dll` sits in
`bin/` beside the executables while the import library `foo.lib` sits in `lib/`.
A recipe reaching for "the lib directory" to find a DLL finds nothing — which is
not hypothetical, since `clingo.dll` is at `Library/bin/clingo.dll` in the
conda-forge win-64 package. Hence `runtimeLibDir` and `linkLibDir` rather than
one `libDir`; the earlier sketch in this document had only `sharedLibDir` and
would have led straight into that trap.

This needed no separate mechanism. Once the setters inline the user's expression
verbatim instead of demanding a literal, a `func` call is just another
expression the compiler resolves — the two changes were one change, and both
have landed. `t_prefix_layout` pins the values against the paths production
actually uses, and pins that a call reaches the registry as its value from
inside both a `library` body and a provisioning setter.
- **The bootstrap floor still applies.** None of this helps `repro.exe` find
  `clingo.dll` while it is *being built* — the engine cannot prepare an
  execution environment for the binary that runs the engine. Build-time staging
  in `scripts/build_apps.sh` stays. What this replaces is the *runtime*
  arrangement for installed executables and for the helpers reprobuild compiles
  after installation.
