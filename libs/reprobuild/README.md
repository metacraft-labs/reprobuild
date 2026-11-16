# reprobuild

The canonical import surface of the Reprobuild DSL. A `repro.nim`, a
`home.nim`, a `system.nim` and any helper module they import name the DSL
through this module tree:

| Import | Provides |
| --- | --- |
| `import reprobuild` | The umbrella: the core project DSL (`package`, `uses`, `nativeBuildDeps`, `buildDeps`, `runtimeDeps`, `executable`, `library`, `build`, `tasks`, `task`, `service`, `config`, `glob`, `shell`, `aggregate`) and the standard prelude (typed filesystem operations, configurables, the active build context, lock-file declarations). |
| `import reprobuild/dsl` | The core project DSL alone, for helper modules that want the smallest compile. |
| `import reprobuild/dsl/<module>` | One standard-library module: `fs`, `operations`, `packaging`, `constructors`, `configurables`, `foreign_env`, `generated_config`, `types`, `packages/nim`, `packages/cargo`, ... |
| `import reprobuild/home` | The profile DSL for a `home.nim`. |
| `import reprobuild/system` | The profile DSL for a `system.nim`. |

```nim
import reprobuild

package hello:
  build:
    discard writeText("build/greeting.txt", "hello")
```

## Discovery is `--path` only

`libs/reprobuild/src` is an ordinary Nim search path. Every place Reprobuild
compiles a recipe or a profile -- the repository's `config.nims`, the
interface-extraction and provider compiles behind dev-env activation and
`repro build`, and the profile compile behind `repro home` / `repro system` --
puts it on the compiler's `--path` together with the other `libs/*/src`
directories. Nothing passes `--import:` or `--include:`.

That is what lets `nim check`, `nimsuggest` and any Nim language server open
a recipe cold: the recipe names its DSL with a normal `import`, so a
`--path` is all a tool needs. A project-wide `--import:reprobuild` (for
example in a directory `nim.cfg`) would instead be applied by Nim to every
module of every compilation in that directory, including the project's own
application sources, which then see `package`, `service` and the rest and
warn `imported and not used: 'reprobuild' [UnusedImport]`.

## Relationship to `repro_project_dsl` and `repro_dsl_stdlib`

The implementation lives in `libs/repro_project_dsl` and
`libs/repro_dsl_stdlib`; the modules here re-export them, so the old and new
names denote the very same symbols and can be mixed while recipes migrate:

| Older import | Canonical import |
| --- | --- |
| `repro_project_dsl` | `reprobuild/dsl` |
| `repro_dsl_stdlib` | `reprobuild` |
| `repro_dsl_stdlib/<module>` | `reprobuild/dsl/<module>` |
| `repro_profile` | `reprobuild/home`, `reprobuild/system` |

The `reprobuild/dsl/<module>` files are generated, one per standard-library
module, by `scripts/generate_reprobuild_dsl_modules.py` (`just
regen-reprobuild-dsl-modules`). Run it after adding, moving or deleting a
module under `libs/repro_dsl_stdlib/src/repro_dsl_stdlib`;
`tests/integration/t_ux_m1_reprobuild_module_hierarchy_and_lsp.nim` fails
while the two trees disagree. A package that moved out of the standard
library (its stdlib module is a one-release `{.error:}` stub) gets no
canonical name.

`reprobuild/system` is named like Nim's implicit `system` module. Unqualified
calls are unaffected; a profile that also wants a qualified
`system.<proc>` from Nim's standard library imports the DSL under another
name: `import reprobuild/system as reproSystem`.

A project file still carrying the legacy name `reprobuild.nim` cannot write
`import reprobuild`: Nim looks in the importing file's own directory first,
so the file finds and imports itself and `package` stays undeclared. Such a
file imports `reprobuild/dsl` (plus any `reprobuild/dsl/<module>` it needs),
or is renamed to `repro.nim`.
