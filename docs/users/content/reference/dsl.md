---
title: Project file and profile syntax
description: The syntax of repro.nim, home.nim and system.nim — the imports, package and dependency sections, executables, libraries, build actions, configuration, tasks, services, typed tool interfaces, activities, hosts, resources and resource types.
kind: reference
persona: build-maintainer
domain: build
order: 20
verifies:
  commands: [build, test, bench, lint, tasks, run, up, down, home apply, infra plan, infra apply]
  tests:
    - tests/integration/t_dsl_reference_snippets_compile_and_docs_build.nim
    - tests/integration/t_ux_m1_reprobuild_module_hierarchy_and_lsp.nim
    - libs/repro_project_dsl/tests/dsl_port/t_dsl_package_level_heads_refuse_extra_arguments.nim
    - tests/integration/t_sc_uses_import_resolves_workspace_project_schema.nim
    - tests/e2e/local-build-engine/t_e2e_repro_run_lists_tasks_and_edges.nim
    - libs/repro_resources/tests/t_rp4_resource_type_macro.nim
    - libs/repro_project_dsl/tests/t_dsl_pinned_siblings.nim
unverified:
  - claim: "`nativeBuildDeps:` entries are tools for the build machine, while `uses:`, `buildDeps:` and `runtimeDeps:` entries are for the machine the result runs on."
    reason: "Read from the dependency-kind declarations in the package macro; no cross-compiling build on this page is executed by a test."
    owner: unassigned
  - claim: "A home profile's `applies:` list limits which concerns repro home apply changes on that host."
    reason: "The test compiles the profile and checks the concern names; it does not apply it."
    owner: unassigned
---

# Project file and profile syntax

This page describes the syntax of reprobuild's three Nim files: the
[project file](glossary.md#project-file) `repro.nim`, the
[home profile](glossary.md#home-profile) `home.nim` and the
[system profile](glossary.md#system-profile) `system.nim`. Each file is an
ordinary Nim module, so the compiler checks it and an editor can navigate it.

Every block of code fenced as `nim` on this page is a complete file. A test
compiles each one with `nim check` against reprobuild's library, so every
example here is accepted by the version of reprobuild this page ships with.
Each example is a `repro.nim` unless the sentence before it names another file.
A block fenced as `text` shows a shape, not a file.

## Files

| File | Describes | Top-level declaration | Applied by |
|---|---|---|---|
| `repro.nim` | A project: its packages, dependencies, build actions, environment, tasks and services | `package <name>:` | `repro build`, `repro run`, `repro up` |
| `reprobuild.nim` | The same; the older name of the project file | `package <name>:` | the same |
| `home.nim` | Your account on one or more machines | `profile "<name>":` | `repro home apply` |
| `system.nim` | A whole machine | `profile "<name>":` | `repro infra plan`, `repro infra apply` |

A file may hold any Nim besides these declarations: constants, procedures,
types and imports of your own modules.

`repro deps refresh` writes a further file, `repro.scanned-deps.nim`, of
`depends_on <package>: <package>, ...` declarations: dependencies between the
packages of a workspace, found by scanning their sources. A project file may
declare one the scan cannot see the same way. Do not edit the generated file
by hand.

## Imports

A file names the part of the language it uses with an ordinary `import`. The
modules form one tree under `reprobuild`:

| Import | Provides |
|---|---|
| `import reprobuild` | The project-file language and its standard prelude: typed file operations (`writeText`, `copyFile`, `ensureDir`, `stamp`), configuration values, the active build context and lock-file declarations |
| `import reprobuild/dsl` | The project-file language alone, without the standard prelude |
| `import reprobuild/dsl/<module>` | One module of the standard library, such as `reprobuild/dsl/fs`, `reprobuild/dsl/packaging` or a package's typed tools, `reprobuild/dsl/packages/<name>` |
| `import reprobuild/home` | The profile language, for `home.nim` |
| `import reprobuild/system` | The profile language, for `system.nim` |

`import reprobuild` does not import the typed tools of every package. A package
named in `uses:` or `nativeBuildDeps:` brings its typed tools into the project
file, so the file calls them without importing anything more
([Build actions](#build-actions)). A package named only in `runtimeDeps:` does
not.

```nim title="repro.nim"
import reprobuild

package hello:
  uses:
    "nim >=2.2 <3.0"

  executable hello:
    discard
```

### Older module names

The older names remain valid and denote the same symbols, so a file can mix
them while it moves to the new ones:

| Older import | Same as |
|---|---|
| `import repro_project_dsl` | `import reprobuild/dsl` |
| `import repro_dsl_stdlib` | `import reprobuild` |
| `import repro_dsl_stdlib/<module>` | `import reprobuild/dsl/<module>` |
| `import repro_profile` | `import reprobuild/home` or `import reprobuild/system` |

```nim title="repro.nim"
import repro_project_dsl
import repro_dsl_stdlib/fs

package legacyImports:
  build:
    discard writeText("build/a.txt", "a")
```

### Two names to watch

- **A project file named `reprobuild.nim` cannot `import reprobuild`.** Nim
  finds the importing file itself first, so the import names the project file.
  Use `import reprobuild/dsl`, and import further modules individually, or
  rename the file to `repro.nim`.
- **`reprobuild/system` is a module named `system`,** like the module Nim
  imports into every file. Unqualified calls are unaffected. A profile that
  calls a procedure of Nim's own module as `system.<name>` imports the
  profile language under another name: `import reprobuild/system as reproSystem`.

A `reprobuild.nim`:

```nim title="reprobuild.nim"
import reprobuild/dsl

package legacyName:
  build:
    shell(command = "true")
```

A `system.nim` that imports the profile language as `reproSystem`:

```nim title="system.nim"
import reprobuild/system as reproSystem

profile "appliance":
  resources:
    fsSystemDirectory(path = "/etc/appliance.d", address = "applianceDir")
```

### How the compiler and editors find the modules

The modules are found through Nim's search path only: reprobuild adds its
library directory with `--path`, and never injects an import with `--import`
or `--include`. A file that states its imports therefore opens cleanly in
`nim check`, `nimsuggest` and any Nim language server, and the application
sources next to it are not affected by the project-file language.

A file named `repro.nim`, `reprobuild.nim`, `home.nim` or `system.nim` that is
opened on its own, by `nim check repro.nim` or by an editor, is checked against
the whole language, `build:` bodies included, with no flag. A program of the
project that imports its `repro.nim` compiles only the declarations it needs,
so it does not compile reprobuild itself and does not see errors in the build
bodies. A helper module of your own with another name is checked against the
whole language when a `<helper>.nims` beside it says so:

```text
switch("define", "reproEvalMode")
```

## Packages

```text
package <name>:
  <section>
  ...
```

A project file holds one or more `package` declarations. The name is a Nim
identifier, or any text in backticks (`` package `my-lib`: ``). This page
describes these sections of a package body:

| Section | Holds |
|---|---|
| `uses:`, `buildDeps:`, `nativeBuildDeps:`, `runtimeDeps:` | The packages this one depends on ([Dependencies](#dependencies)) |
| `platforms [<platform>, ...]` | The platforms the package builds on: `linux`, `macos`, `windows` |
| `defaultToolProvisioning "<mode>"` | How the package's tools are obtained when the command line does not say, such as `"path"` |
| `config:` | Configuration values ([Configuration](#configuration)) |
| `executable <name>`, `library <name>`, `files <name>` | The package's artifacts ([Executables, libraries and files](#executables-libraries-and-files)) |
| `build:` | Build actions of the package as a whole ([Build actions](#build-actions)) |
| `devEnv:` | The development environment, its activities and its tasks ([Development environment and tasks](#development-environment-and-tasks)) |
| `service <name>:` | A service the package runs ([Services](#services)) |

A package body accepts some further sections, for packaging software built
from fetched sources and for services shared between projects. This page does
not describe them yet:

| Section | Holds |
|---|---|
| `provisioning:` | Where the package itself can be obtained: `nixPackage`, `tarball`, `scoopApp` and `environmentPrefix` entries |
| `toolProvisioning` | Another name for `defaultToolProvisioning` |
| `versions:` | One `"<version>":` entry per version of the package |
| `fetch:` | The pinned upstream source: its URL, its hash and how it is unpacked |
| `outputs:` | The package's named outputs, one `output <name>:` each |
| `mesonOptions:`, `cmakeFlags:`, `configureFlags:`, `makeFlags:`, `ninjaFlags:` | Flags for the build system the convention runs, one string per line |
| `variant <config value>:`, `validate:` | Dependencies chosen by a configuration value, and a check over the configuration values |
| `bootloader:` | Boot-menu entries for a package that is part of a system image |
| `runtimeLibrary "<name>", dir = ...` | Where a library the package provides lies in its installed files |
| `usesImportPath "<dir>"` | A directory of modules that `uses:` entries import in place of the bundled ones |
| `pinned:` | Repositories the lock pins and a CI job clones, that no part of the build reads ([Pinning a sibling you only clone](#pinning-a-sibling-you-only-clone)) |
| `dslDeps:` | Packages whose project files export Nim declarations this one imports |
| `lockFile <name>` | The named lock file the package's dependencies are resolved in |
| `packageSource "<package>", "<source>"` | Where a depended-on package's built result comes from: `"store"` or `"registry:<name>"` |
| `enactCertificatePolicy <policy>` | The test-certificate policy the repository applies to its branches |
| `environment <name>:`, `instanceOverrides <package>.<service>:`, `contribute:` | Bindings to services shared between projects |

Any other statement in a package body is ordinary Nim, so a misspelt section
is not ignored: it is a compile error naming the misspelt word.

```nim title="repro.nim"
import reprobuild

package portable:
  platforms [linux, macos, windows]
  defaultToolProvisioning "path"

  files assets:
    build:
      discard writeText("build/assets/readme.txt", "assets\n")
```

## Dependencies

Four sections name the packages a package depends on. Each entry is a string:
a package name, optionally followed by version constraints such as
`>=2.2 <3.0`.

| Section | The dependency is |
|---|---|
| `uses:` | A tool or library the build uses. The common case; reprobuild treats it as `buildDeps:` |
| `buildDeps:` | A library or tool for the platform the result runs on, such as a library the program links against |
| `nativeBuildDeps:` | A tool that runs on the build machine during the build, such as a code generator, `pkg-config` or a compiler. When reprobuild cross-compiles, these come from the build machine's platform |
| `runtimeDeps:` | A tool or library the result needs when it runs |

Outside cross-compilation the build machine and the target are the same, and
`uses:` is enough. Name a dependency in `nativeBuildDeps:` when it must run
during the build even when the result is for another platform.

A `when` inside a dependency section is decided by the compiler, so any
condition Nim can evaluate selects entries:

```nim title="repro.nim"
import reprobuild

package imageTools:
  uses:
    "zlib >=1.3"
  nativeBuildDeps:
    "pkg-config"
    "cmake >=3.20"
  buildDeps:
    "openssl >=3.0"
  runtimeDeps:
    "curl"
    when defined(linux):
      "patchelf"

  executable imageTool:
    name: "image-tool"
```

### Pinning a sibling you only clone

A CI job sometimes clones a sibling repository beside the checkout and runs a
test harness against it, while nothing in the project's build reads it. The
clone steps take the sibling's revision from the project's `repro.lock`, so
the lock has to pin it. Naming it in `uses:` would do that, but `uses:` also
makes the sibling a build dependency: its own `repro.nim` is compiled with
yours and the lock records everything it depends on. `pinned:` pins the
sibling and does nothing else:

```nim title="repro.nim"
import reprobuild

package recorderTests:
  uses:
    "nim >=2.2 <3.0"
  pinned:
    "codetracer"
    "codetracer-vscode-extension"
```

Each entry is a repository name, with no version constraint. `repro lock
refresh` records the checkout's current commit for each one, the same way it
does for a `uses:` sibling, and the sibling's own `repro.nim` is never
compiled or read. The sibling must be checked out beside your repository (or
already pinned in the committed lock). A name that appears in both `uses:` and
`pinned:` of one package is a compile error: a `uses:` already pins its
sibling.

## Executables, libraries and files

```text
executable <name>
executable <name>:
  <member>
library <name>
library <name>:
  <member>
files <name>:
  build:
    <actions>
```

An artifact is something the package produces. Without a body, or with a body
of `discard`, the language's [convention](glossary.md#convention) finds the
sources and builds the artifact.

| Member | Allowed in | Meaning |
|---|---|---|
| `name: "<file name>"` | `executable` | The file name of the program when it differs from `<name>`, such as `"image-tool"` |
| `kind: <kind>` | `library` | `static`, `shared`, `both` or `headerOnly` |
| `exportedPath: "<dir>"` | `library` | The directory that holds the library's sources for a consumer, by default `src` |
| `build:` | `executable`, `library`, `files` | The actions that produce the artifact ([Build actions](#build-actions)) |
| `cli:` | `executable` | The program's typed command-line interface ([Typed tool interfaces](#typed-tool-interfaces)) |
| `lockFile <name>` | `executable`, `library` | The named lock file the artifact's dependencies are resolved in, when it differs from the package's |

Writing anything beside the name on the head line, as in
`executable tool, extra:`, is a compile error.

```nim title="repro.nim"
import reprobuild

package `my-lib`:
  library core:
    kind: shared
    exportedPath: "src"

  library headers:
    kind: headerOnly

  executable `my-tool`:
    name: "my-tool"
    build:
      discard writeText("build/version.txt", "1.0\n")
```

## Build actions

A `build:` block, at package level or inside an artifact, is Nim code that
declares [actions](glossary.md#action). Each call below adds one action to the
[build graph](glossary.md#build-graph) and returns a value of type
`BuildActionDef`, which other calls take to order actions or to name them.

| Call | Made available by | Declares |
|---|---|---|
| `writeText(output, text)` | `import reprobuild` | An action that writes `text` to `output` |
| `copyFile(source, output)` | `import reprobuild` | An action that copies a file |
| `ensureDir(path)` | `import reprobuild` | An action that creates a directory |
| `stamp(output, title, entries)` | `import reprobuild` | An action that writes a stamp file listing `entries` |
| `shell(command, ...)` | `"sh"` in `uses:` | An action that runs `command` in a shell |
| `<package>.<tool>(...)` | `"<package>"` in `uses:` or `nativeBuildDeps:` | An action that runs a package's typed tool, such as `nim.c(source = ..., binary = ...)` |

These parameters are common to the calls above:

| Parameter | Meaning |
|---|---|
| `actionId` | The action's stable identifier |
| `after` | Actions that must finish first |
| `cacheable` | `false` when the action's result must not be reused (not `ensureDir`) |
| `extraInputs`, `extraOutputs` | Files the action reads or writes that order it in the graph before reprobuild has observed a run of it (`shell` only) |
| `extraEnv` | Environment variables set on the action; they are part of its cache key (`shell` only) |

reprobuild records what each action reads while it runs, so an action's inputs
are what it was observed to read, not a list you maintain. There is no `glob`
function for declaring inputs. A tool that reports its inputs in a dependency
file takes `dependencyPolicy = makeDepfilePolicy(depfile = "<path>")`, whose
path may be a glob pattern.

The core language also has a `shell(command, id, deps, outputs, cwd)` form,
without a return value. It records a step of a package that is built from
fetched sources, where `$out`, `$fetch` and `$extracted` in `command` name the
output, the download and the unpacked sources.

### Naming and grouping actions

| Call | Effect |
|---|---|
| `target(name, action)` or `target(name, [actions])` | Gives actions a name that `repro build <name>` selects |
| `aggregate(name, actions = [...], targets = [...])` | A named target that stands for other actions and targets |
| `collect(name, [actions])` | Adds actions to a collection. `test`, `bench`, `lint`, `docs` and `package` are the conventional collections, which `repro test`, `repro bench` and `repro lint` build |
| `defaultBuildAction(nameOrAction)` | What `repro build` builds when no target is named |

When no target is named and the package sets no `defaultBuildAction`,
`repro build` leaves out the actions collected in `test`, `bench` and `lint`.

```nim title="repro.nim"
import reprobuild

package site:
  build:
    let page = writeText("build/index.html", "<h1>hello</h1>\n",
      actionId = "site.page")
    let published = copyFile("build/index.html", "build/public/index.html",
      actionId = "site.publish", after = [page])
    discard target("publish", published)
    discard aggregate("site", actions = [page, published])
    discard collect("docs", [published])
    defaultBuildAction("site")
```

```nim title="repro.nim"
import reprobuild

package gates:
  uses:
    "sh"

  build:
    let lint = shell("sh scripts/lint.sh", actionId = "gates.lint",
      extraInputs = ["scripts/lint.sh"])
    let unit = shell("sh scripts/unit.sh", actionId = "gates.unit",
      extraInputs = ["scripts/unit.sh"], after = [lint],
      extraEnv = [("LANG", "C.UTF-8")])
    discard collect("lint", [lint])
    discard collect("test", [unit])
```

A typed tool is called through the package's value, here `nim`:

```nim title="repro.nim"
import reprobuild

package app:
  uses:
    "nim >=2.2 <3.0"

  build:
    discard nim.c(source = "src/app.nim", binary = "build/bin/app")
```

A helper module of your own, outside any package, imports a package's typed
tools explicitly. The module and the package's value share a name, so the
helper imports the module under another one. A `build_helpers.nim`:

```nim title="build_helpers.nim"
import reprobuild/dsl
import reprobuild/dsl/packages/nim as nimTools

proc compileApp*(): BuildActionDef =
  nim.c(source = "src/app.nim", binary = "build/bin/app")
```

Next to it, `build_helpers.nims` lets `nim check build_helpers.nim` and an
editor check it against the whole language
([How the compiler and editors find the modules](#how-the-compiler-and-editors-find-the-modules)).

## Configuration

```text
config:
  <name>: <Type> = <default>
```

A `config:` block declares the package's configuration values. Each line names
a value, its Nim type and, optionally, its default. Code in the package reads
a value by its name. A
`config:` block written inside an [activity](#development-environment-and-tasks)
declares values of that activity.

```nim title="repro.nim"
import reprobuild

package server:
  config:
    title: string = "My server"
    port: int = 8080

  executable server:
    discard
```

## Development environment and tasks

```text
devEnv:
  activity "<name>"
  activity <name>:
    <config and services>
  task "<name>", command = "<command>", description = "<text>"
  <environment setting>
```

The `devEnv:` block declares the project's
[development environment](glossary.md#development-environment): the
[activities](glossary.md#activity) it offers, the variables and paths it sets,
and its [tasks](glossary.md#task). `repro tasks` lists the tasks and
`repro run <task>` runs one inside the environment.

| Statement | Declares |
|---|---|
| `activity "<name>"` | An activity that commands select with `--activity=<name>` |
| `activity <name>:` with a body | An activity with its own `config:` values and `service` blocks |
| `task "<name>", command = "...", description = "...", activities = [...]` | A task; with `activities`, it is available only when one of them is selected |
| `setEnv(name, value)`, `unsetEnv(name)` | An environment variable |
| `prependPath(name, value)`, `appendPath(name, value)` | An entry on a path list such as `PATH` |
| `useTool(name)` | A tool the environment puts on `PATH` |
| `useFlakeDevShell()` | The environment of the repository's Nix flake; imported by `reprobuild/dsl/foreign_env` |

Every environment statement takes an optional `activities` list with the same
meaning as on `task`. Tasks are declared only here: there is no separate
`tasks:` section.

```nim title="repro.nim"
import reprobuild

package devtools:
  devEnv:
    activity "default"
    activity "docs"
    setEnv("APP_ENV", "development")
    prependPath("PATH", "tools/bin")
    task "test",
      command = "cargo test --workspace",
      description = "Run the full test suite"
    task "serve-docs",
      command = "mdbook serve",
      description = "Serve the documentation",
      activities = ["docs"]
```

## Services

```text
service <name>:
  <setter>
  ...
```

A `service` block declares a [service](glossary.md#service): a long-running
process that `repro up` starts and `repro down` stops. Written at package level
it belongs to the package; written inside an `activity` in `devEnv:`, it runs
when that activity is selected and can use the activity's `config:` values.

A service body holds setters and nothing else; any other statement is a
compile error.

| Setter | Meaning |
|---|---|
| `executable <name>` | The program the service runs |
| `args "<arg>", ...` | Arguments; repeatable |
| `description "<text>"` | A description |
| `workingDirectory "<dir>"`, `stateDirectory "<dir>"` | The directory it runs in, and a directory it keeps state in |
| `env("<NAME>", "<value>")` | An environment variable; repeatable |
| `runtimeFile <output>` | A build output the service reads |
| `readiness <probe>` | How reprobuild tells that the service is ready |
| `restartOnCrash`, `hotReload`, `reloadOnChange <output>, "<signal>"` | What happens on a crash or on a rebuilt output |
| `on <trigger>:` | Actions on `start`, `stop`, `crash`, `rebuild <name>` or `change <output>` |
| `scope <scope>` | `project`, `workspace`, `user` or `system` |
| `` `type` ``, `execStart`, `restart`, `user`, `group`, `wantedBy`, `wants`, `requires`, `before`, `after` | The fields of the systemd unit, for a service installed as one |
| `identity derived` or `identity stable "<id>"`, `compatibility <n>`, `instance:`, `converge <point>, ...` | For a service other projects share: how its instance is identified, its major compatibility version, the instance's own settings, and the points other projects contribute to |

```nim title="repro.nim"
import reprobuild

package api:
  devEnv:
    activity backend:
      config:
        port: int = 8080
      service api:
        description "The API server"
        args "--port", $port
        restartOnCrash

  service worker:
    args "--queue", "default"
```

## Typed tool interfaces

```text
executable <name>:
  cli:
    pos <name> is <Type>
    flag <name> is <Type>
    boolFlag <name>
    subcmd "<name>":
      <parameters>
```

A `cli:` block declares the command line of a package's program. Another
project that names the package in `uses:` calls the program as typed Nim, such
as `server.serve(socket = "...")`; a wrong parameter name or type is a compile
error in the calling project rather than a failed build.

| Statement | Declares |
|---|---|
| `pos <name> is <Type>` | A positional argument |
| `flag <name> is <Type>` | An option that takes a value |
| `boolFlag <name>` | An option that takes no value |
| `subcmd "<name>":` | A subcommand, with its own parameters; subcommands nest |
| `call:` | The program's own command line, when it has no subcommand |

A parameter also takes named arguments: `alias`, `required`, `repeated`,
`format`, `placement` and `position` shape its command line, and
`role = input` or `role = output` marks a parameter that names a file the
program reads or writes. These statements describe the build-graph side of a
command, and a nested `subcmd` inherits them: `outputs` and `optionalOutputs`
name the parameters that hold the command's outputs, `removeBeforeRun` the
outputs to delete before it runs, and `dependencyPolicy`, `nonDeterminism` and
`inputCheckPolicy` how its dependencies are gathered, whether its results may
differ between runs, and how its inputs are checked for changes.
`subTools`, directly under `cli:`, names the further programs the program
runs.

```nim title="repro.nim"
import reprobuild

package server:
  executable server:
    name: "server"
    cli:
      subcmd "serve":
        flag socket is string
        boolFlag verbose
      subcmd "status":
        flag format is string
```

### Shell completion files

When a package builds an executable that has a `cli:` block with a Nim
compile (`nim c`, `cpp` or `objc`, whichever constructor records it), the
build also writes the program's Bash, Zsh, Fish and PowerShell completion
scripts to `build/completions/<binary>/`: `<program>.bash`, `_<program>`,
`<program>.fish` and `<program>.ps1`. The package declares nothing for it.

The scripts are generated from the description and from the entry list the
compile writes (`build/entrypoints/<binary>.entrypoints.json`, through
nim-entrypoints' `-d:entrypointsManifest`); the program is never run, so a
binary built for another machine gets its scripts too. A program that
registers nim-entrypoints' `describeProgram` is asked for candidates through
`--entrypoint=complete`, and any other program through clispec's
`__complete`. The compile is the one whose `--out:` file is named after the
executable's binary; two such compiles in one package are refused. An
executable no Nim compile builds gets no scripts. The paths do not depend on
`--target`, so a cross build writes the same files as a native one.

## Profiles

```text
profile "<name>":
  activity <name>:
    <package references, when blocks, stow:, resources:>
  config:
    <package>:
      <setting> = <value>
  hosts:
    "<host>": [<activity>, ...]
  resources:
    <resource constructors>
```

`home.nim` and `system.nim` each declare one `profile`. Its body holds these
sections:

| Section | Holds |
|---|---|
| `activity <name>:` | An [activity](glossary.md#activity): packages to install, and the `stow:` and `resources:` blocks that belong to it |
| `config:` | Settings of installed packages, one block per package |
| `hosts:` | Which activities each host selects |
| `resources:` | Resources the profile keeps in their declared state on every host |
| `data:`, `catalogs:`, `adapterPreference:` | Data files the plan reads, package catalogs the profile imports, and the order in which a package's installation methods are preferred |
| `addOn:`, `baseOs:` | For a machine whose system reprobuild manages on top of a distribution: the `/etc` paths it manages there; and the base operating-system image to start from |

Any other section is a compile error.

### Activities

An activity body lists package references, one per line: a bare name
(`git`), a name in backticks or quotes for one that is not a Nim identifier,
or `package("<name>", binaries = @["<program>"])` when the programs are named
differently from the package. It may also hold:

- `when <predicate>:` with a body of package references, applied only where the
  predicate holds. The predicates are `windows()`, `macos()`, `linux()`,
  `bsd()`, `wsl()`, `nixos()`, `x86_64()`, `arm64()` and `arm32()`, and `host()` compared
  with `==`, `!=` or `in`, combined with `and`, `or` and `not`.
- `stow:` with the names of directories under `stow/` to link into your home
  directory on hosts that select the activity.
- `resources:` with resources that exist only on hosts that select the
  activity.

### Hosts

Each entry of `hosts:` names a host, by its host name, and either lists its
activities or opens a block:

| Key in the block form | Meaning |
|---|---|
| `activities: [...]` | The activities the host selects; without it, `default` only |
| `applies: [...]` | The concerns reprobuild changes on the host: `packages`, `applications`, `files`, `environment`, `services`, `settings`. Without it, all of them |
| `system: full`, `system: managedElsewhere`, `system: managedElsewhere("<name>")` or `system: addOn` | Who manages the host's system: this configuration (`full`, the default), something else, which the optional name identifies, or reprobuild on top of the distribution's own system (`addOn`). The block form, `mode:` with `activities: [...]`, also selects activities of the system profile |

An unknown key, an unknown concern or a concern named twice is a compile error
naming the host.

A `home.nim`:

```nim title="home.nim"
import reprobuild/home

profile "me":
  activity default:
    git
    neovim
    when linux():
      patchelf

  activity develop:
    gh
    package("ripgrep", binaries = @["rg"])
    stow:
      "nvim"
      "git"
    resources:
      envUserVariable(name = "EDITOR", value = "nvim")

  config:
    git:
      userName = "Ada Lovelace"

  hosts:
    "laptop": [develop]
    "build-box":
      activities: [default]
      applies: [packages, files]

  resources:
    fsUserFile(hostFile = "~/.config/app/app.conf", content = "answer = 42\n")
```

### Resources

A `resources:` block holds calls to resource constructors. Each call declares
one [resource](glossary.md#resource) and takes named arguments, including an
optional `address`, which names the resource in plans and in `dependsOn` lists,
and `dependsOn`, which lists the addresses of resources to create first.

The constructors and the kind of resource each declares:

<!-- resource-constructors:begin -->
| Constructor | Resource kind |
|---|---|
| `envUserPath` | `env.userPath` |
| `envUserVariable` | `env.userVariable` |
| `fsManagedBlock` | `fs.managedBlock` |
| `shellIntegration` | `shell.integration` |
| `fsUserFile` | `fs.userFile` |
| `systemdUserUnit` | `systemd.userUnit` |
| `linuxDconfKey` | `linux.dconfKey` |
| `linuxKdeConfigKey` | `linux.kdeConfigKey` |
| `homebrewFormula` | `pkg.homebrewFormula` |
| `homebrewCask` | `pkg.homebrewCask` |
| `launchdUserAgent` | `launchd.userAgent` |
| `vscodeExtension` | `vscode.extension` |
| `windowsRegistryValueHKCU` | `windows.registryValueHKCU` |
| `windowsStartup` | `windows.startup` |
| `windowsOptionalFeature` | `windows.optionalFeature` |
| `windowsCapability` | `windows.capability` |
| `windowsService` | `windows.service` |
| `windowsScheduledTask` | `windows.scheduledTask` |
| `windowsRegistryValueHKLM` | `windows.registryValueHKLM` |
| `windowsVsInstaller` | `windows.vsInstaller` |
| `windowsFirewallRule` | `windows.firewallRule` |
| `windowsAcl` | `windows.acl` |
| `macosSystemDefault` | `macos.systemDefault` |
| `launchdSystemDaemon` | `launchd.systemDaemon` |
| `macosDarwinSystemModule` | `macos.darwinSystemModule` |
| `systemdSystemUnit` | `systemd.systemUnit` |
| `systemdSystemDropIn` | `systemd.systemDropIn` |
| `systemdSystemTimer` | `systemd.systemTimer` |
| `systemdUnitState` | `systemd.unitState` |
| `secretFile` | `secrets.secretFile` |
| `fsSystemFile` | `fs.systemFile` |
| `fsSystemDirectory` | `fs.systemDirectory` |
| `envSystemVariable` | `env.systemVariable` |
| `passwdUser` | `passwd.user` |
| `passwdGroup` | `passwd.group` |
| `osTimezone` | `os.timezone` |
| `osHostname` | `os.hostname` |
| `linuxSysusersEntry` | `linux.sysusersEntry` |
| `linuxSysctl` | `linux.sysctl` |
| `linuxUdevRule` | `linux.udevRule` |
| `linuxPolkitRule` | `linux.polkitRule` |
| `linuxTmpfilesRule` | `linux.tmpfilesRule` |
| `linuxSudoersRule` | `linux.sudoersRule` |
| `linuxFirewallRule` | `linux.firewallRule` |
| `linuxNixDaemonSetting` | `linux.nixDaemonSetting` |
| `linuxNixosSystemModule` | `linux.nixosSystemModule` |
| `addOnTool` | `linux.addOnTool` |
| `fhsSandbox` | `linux.fhsSandbox` |
<!-- resource-constructors:end -->

A `system.nim`:

```nim title="system.nim"
import reprobuild/system

profile "server":
  activity default:
    git

  resources:
    fsSystemDirectory(path = "/etc/app.d", address = "appDir")
    fsSystemFile(path = "/etc/app.d/app.conf", content = "port = 8080\n",
      mode = "0644", address = "appConfig", dependsOn = @["appDir"])
```

## Resource types

```text
resourceType "<type id>":
  attrs: <attribute object type>
  wrapper: <constructor name>
  determinism: <rdVolatile or another determinism>
  driver: <ResourceProviderDriver value>
  attr <name>: <Type>
```

A `resourceType` declaration defines a new kind of resource, as a Terraform
provider does: its attributes, and a driver whose procedures identify the real
object, compute the digest of its desired state, read its current state and
change it. The declaration also defines a typed constructor, named by
`wrapper:`, that a project file calls to declare a resource of the type.

`resourceType` and the driver types come from `import repro_resources`, which
is not part of the `reprobuild` module tree. A resource type is declared in a
project file, and becomes part of the interface that the project exports to
the other projects of a workspace.

```nim title="repro.nim"
import std/options
import reprobuild
import repro_resources

type
  ContainerAttrs = object
    image*: string
    cpus*: int

proc identityOf(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address

proc digestOf(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address & ":" & inst.typeId)

proc observeOf(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  result.present = recorded.isSome

proc applyOf(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: identityOf(inst), present: true)

let containerDriver = ResourceProviderDriver(identity: identityOf,
  digest: digestOf, observe: observeOf, apply: applyOf)

resourceType "example.container":
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr image: string
  attr cpus: int

package containers:
  executable placeholder:
    discard
```

## Related

- [Glossary](glossary.md)
- [Commands](commands/index.md)
- [Conventions and the three modes](../concepts/conventions-and-modes.md)
- [Machines and profiles](../concepts/machines-and-profiles.md)
- [Resources and state](../concepts/resources-and-state.md)
