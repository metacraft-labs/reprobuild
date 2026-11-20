---
title: Find out why two builds of a library are not shared
description: Select a library's compile-time features per application so each feature set is built once, keep two solved graphs apart with named lock files, and ask repro cache explain which flag, define, input, toolchain or dependency makes two cache keys differ.
kind: how-to
persona: build-maintainer
domain: build
order: 40
platforms: [linux]
verifies:
  commands: [build, cache key, cache explain, cache sharing]
  tests:
    - tests/integration/t_cargo_and_cmake_cross_checkout_sharing_is_declared_as_measured.nim
    - tests/integration/t_cargo_two_binaries_different_features_are_not_shared_wrongly.nim
    - libs/repro_build_engine/tests/t_cross_checkout_sharing_refusal.nim
    - tests/integration/t_same_library_two_feature_sets_two_artifacts.nim
    - tests/integration/t_key_difference_explanation_names_the_cause.nim
    - libs/repro_local_store/tests/t_key_explanation_classifies_each_cause.nim
    - libs/repro_lock_gen/tests/t_one_library_two_consumers_two_instances.nim
unverified:
  - claim: "A CMake project configured with the store's compiler as CMAKE_C_COMPILER reports and measures none."
    reason: "Measured by hand on Linux x86_64 on 2026-11-19 with repro 0.2.28; the test configures its CMake fixture with the compiler on PATH only."
    owner: unassigned
  - claim: "The repro.nim fragment on this page builds."
    reason: "It is an excerpt of the build file t_same_library_two_feature_sets_two_artifacts.nim writes and builds; no test compiles the fragment as printed here."
    owner: unassigned
  - claim: "Two artifacts designated to two lock files get their dependencies solved in two graphs, through the lockFile spelling shown."
    reason: "t_one_library_two_consumers_two_instances.nim checks the per-lock-file solve, not the DSL spelling that designates an artifact."
    owner: unassigned
  - claim: "The captured output on this page."
    reason: "Run by hand on Linux x86_64 on 2026-11-19 with repro 0.2.28 built from the reprobuild change that adds these commands (on agents 429023cd57), the project paths shortened to /src; no scenario re-runs it."
    owner: unassigned
---

# Find out why two builds of a library are not shared

This guide shows how two applications that use one library get one library
build when they configure it the same way and two when they do not, and how
to ask reprobuild which difference keeps two builds apart.

## How a feature selection becomes its own library build

Reprobuild reuses an action's result when the action's cache key matches.
The key of a compile is computed from what the compile is: its command line
(every flag and define), its declared environment (which names the
toolchain), the content of the files it reads, and the keys of the actions
that produce its inputs. Paths inside the checkout are named relative to the
project, so the same compile in two checkouts at different paths has one key.

So an application that selects a library's compile-time features does it by
passing them to the library's compile. Here the application's build file
compiles its copy of `mathlib` with the features it lists:

```nim fragment
  build:
    let root = activeProviderProjectRoot()
    # The library features this application selects.
    let features: seq[string] = @["MATHLIB_WITH_MUL"]
    var defines: seq[string] = @[]
    for feature in features:
      defines.add("-D" & feature)
    let libObj = root / ".repro/build/mathlib/obj/add.o"
    let libCompile = buildAction(id = "mathlib-compile-add",
      call = inlineExecCall(@["gcc", "-c", "-O2"] & defines &
        @["-I", root / "vendor/mathlib/include", "-o", libObj,
        root / "vendor/mathlib/src/add.c"], root),
      inputs = @[root / "vendor/mathlib/src/add.c"],
      outputs = @[libObj], pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["gcc"])
```

Two applications that list different features get two keys, so the library
is compiled and archived once for each, and the two archives differ in what
the feature adds. A third application that lists the same features as the
first gets the first one's key: on the same machine its build takes the
first build's library instead of compiling it. Nothing has to be declared
for this; it follows from the key.

The compile and archive edges take part in this sharing when their input
check is content-based, which the `gcc`, `clang` and `ar` tools declare, and
when every file the compiler reads lies under the project, the workspace or
reprobuild's store. A toolchain that reprobuild realizes into its store
(`--tool-provisioning=tarball` on Linux x86_64) meets that; one read from
`/nix/store` or `/usr` builds and caches in each checkout separately.

:::note
A C or C++ project built by convention, with no `build:` block, compiles
every source with the convention's fixed flags. Its consumers cannot select
features of a library it builds, so every consumer gets the same build. To
select features, declare the library's edges in a build file as above.
:::

## When two applications need two solved graphs

A build file's feature list needs no dependency solve. A different case is
two applications in one workspace that need different *resolutions* of a
package, such as two versions of a library. The project's lock file holds
one solved graph, which resolves each package once, so it cannot hold both.

Give each application its own named lock file: write `lockFile <name>` in
the body of the `executable` or `library` whose dependencies are to be
resolved in it ([Executables, libraries and
files](../../reference/dsl.md#executables-libraries-and-files)). Each
application's dependencies are then solved in their own graph, the shared
library is built once per graph, and the two builds have different keys
because each graph's identity is part of them. Bind a lock file to a file on
the command line with `--lock <name>=<path>`.

## Ask why two keys differ

`repro cache key` prints the key of one action and the evidence it is
computed from; `repro cache explain` compares two. Name an action as
`<project>#<action-id>`. Neither command builds anything.

```bash
repro cache explain ../app-with-mul#mathlib-compile-add \
  ../app-plain#mathlib-compile-add --tool-provisioning=tarball
```

```text
different-key (may not substitute)
  a: mathlib-compile-add in /src/app-with-mul weak 074c9fc7d183e8ad265af97420098b4008bc13f08b4ee11437c87cfc01599e76
  b: mathlib-compile-add in /src/app-plain weak 6a897d968758aaf42657a150a081ad9ad6bc6e0a810817749f0ae29fa626f2eb
  define MATHLIB_WITH_MUL: `-DMATHLIB_WITH_MUL` vs (absent) (argv, planned)
```

Asked about the archive edges instead (`#mathlib-archive`), whose own
command lines are the same, the answer is a `dependency` on the object file
whose compile differs, with the define nested under it.

Each line under the header is one cause, of one of these kinds:

| Kind | The two actions differ in |
|---|---|
| `define` | A preprocessor or compile-time define: `-D`, `-U`, or Nim's `-d:` |
| `flag` | Any other option, such as `-O1` against `-O2` or another `-I` directory |
| `toolchain` | The program run, or the toolchain its `PATH` names; the cause shows each side's tool and version when the path states them |
| `input` | A file it reads: other content, or read by one side only |
| `dependency` | An input another action produces, whose own key differs; the cause lists why, nested under it |
| `environment` | Another environment variable |
| `argument`, `outputs`, `working-directory`, `action` | A positional argument, the declared outputs, the working directory, or the kind of action |

When the explanation finds a difference in the command line, environment or
declared inputs, files the actions read differently because of it are listed
as `also observed`, not as further causes: another compiler reads other
files because it is another compiler.

### Before and after a build

Without any build, `explain` compares everything the actions declare: their
flags, defines, environment and toolchain, the content of their source
files, and the keys of the actions that produce their inputs. That answers
every case above except one: two actions whose declarations all agree are
`undetermined`, because the headers and other files a compile reads become
known only when it runs.

Once one of them has been built, the build's record says what it read.
`explain` checks those files in the other checkout, which is what a build
there does before it reuses the result, and answers `same-key` (the build
would be reused) or names the file that differs.

### Compare two actions planned under different options

Each side of `explain` can also be a file that `repro cache key --json`
wrote, for two sides that one command cannot plan, such as the same project
with two `--tool-provisioning` modes:

```bash
repro cache key .#mathlib-compile-add --json --tool-provisioning=tarball > store-gcc.json
repro cache key .#mathlib-compile-add --json --tool-provisioning=path > host-gcc.json
repro cache explain store-gcc.json host-gcc.json --json
```

A key file is checked before it is compared: a file whose recorded command
line does not produce the key it names, or whose recorded inputs do not
produce its recorded key, is refused.

## Read the answer from a program

`--json` prints a document whose `schema` field names its format:
`reprobuild.action-key.v1` for `key` and `reprobuild.key-explanation.v1` for
`explain`. In the explanation:

| Field | Holds |
|---|---|
| `verdict` | `same-key`, `different-key` or `undetermined` |
| `substitutable` | `true` when the keys are the same and both actions take part in sharing between checkouts |
| `a`, `b` | Each action's `weak` key (its declared description), `strong` key when one is recorded or evaluated, and whether it takes part in sharing (`eligible`, `refusal`) |
| `causes` | One object per difference: `kind`, `component` (`argv`, `env`, `cwd`, `declared-input`, `static`, `observed-input`), `subject`, the values `a` and `b` (`null` where a side has none), `evidence` (`planned` or `recorded`), and `because` for a `dependency` |
| `alsoObserved` | Recorded differences that follow from the causes |
| `unanswered` | What could not be compared, and what would answer it |

A `v1` document only gains fields. A field whose meaning changes, or a new
cause kind, comes with a new schema name, so a program that switches on
`kind` can refuse a schema it does not know. Both commands exit 0 whenever
they print an answer; read `verdict`, not the exit status.

## Ask whether another checkout can reuse a project's builds

Two checkouts of one project at different paths share a library build only
when the actions that build it can be served across checkouts. Whether they
can depends on the build style and on where the toolchain comes from, and
`repro cache sharing` answers it from the planned graph, without building:

```sh
repro cache sharing                  # the current project's default target
repro cache sharing build#all        # a CMake build directory's `all`
repro cache sharing --json --tool-provisioning=tarball
```

For each action it says whether its cached result can be served to another
checkout on this host, and if not, the first reason: the action is not
cacheable; the portable cache is off (`REPRO_PORTABLE_CACHE=0`); the action
is declared `host-bound` or `volatile`; its input-check policy is not
`checksum` or `hybrid`; its dependency evidence is a depfile or another tool
report that the monitor does not validate; it is a built-in step that reads
more than its declared inputs; it runs with `--unsafe-preserve-outputs`; its
program lies outside every root the cache knows how to name in another
checkout (a toolchain under `/nix/store` or `/usr`); or it declares no
output. These are the checks a build itself makes before it keeps a result
for another checkout. For the project it prints one of:

| `sharing` | Meaning |
|---|---|
| `per-library` | Some actions can be served to another checkout, each on its own: a library built once can be reused by the next checkout. |
| `per-build` | The selection is one cacheable action, and it can be served: the whole build is reused, or rebuilt, as a unit. |
| `none` | Nothing this selection builds is served to another checkout. Each checkout builds it again (and still reuses its own earlier builds). |

`none` is certain. `per-library` and `per-build` say what can be served once
the actions have run: an action can still read a file outside the cache's
roots when it runs, or write an output that names its checkout (a debug
build without `-ffile-prefix-map`), and its result then stays with its
checkout.

What it reports for the common build styles on Linux:

- A library compiled and archived by the C/C++ convention or by a build
  file's `gcc` and `ar` calls, with `--tool-provisioning=tarball` (the
  toolchain reprobuild provisions into its store): `per-library`. The
  compile and archive actions are served; the link of an executable is not,
  because the executable names the store's path.
- Cargo through the typed `cargo` tool, whether one action builds the whole
  workspace or one action builds a package, a binary or a library with
  chosen features: `none`. Each checkout reuses only its own builds.
- A CMake project configured with `-G Reprobuild`: `none`, with the compiler
  on `PATH` and also with the store's compiler as `CMAKE_C_COMPILER`.

Within one checkout every style keeps feature sets apart: a library built
with one binary's features is never reused for another binary that enables
other features, and switching between the two rebuilds it.

With `--json` the document's `schema` is `reprobuild.cache-sharing.v1`, with
the fields `sharing`, `shareableActions`, `cacheableActions` and `actions`
(each with `id`, `shareable` and, when it cannot be shared, `reason`). As
with the other documents, a `v1` document only gains fields.
