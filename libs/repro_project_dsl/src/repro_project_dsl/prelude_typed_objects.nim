## Project-DSL-Composition M5 — per-section typed-object prelude.
##
## Mirrors the v8 prototype's `intended/reprobuild.nim` prelude (lines
## 41-74). Each top-level `package <name>:` block, after M5, has a
## companion `PackageBuild["<name>"]` namespace addressable through
## section-accessor templates the `package` macro emits.
##
## The existing production DSL emits one per-package const named after
## the package (e.g. `reprobuild` for `package reprobuild:`) whose type
## is the per-package object `ReprobuildPackage`. M5 unifies the M3
## `Package[name]` cross-project handle with that existing const by
## attaching a `build*` template (and siblings) directly to the
## per-package object — see `macros_b.nim`'s `generatedCrossProjectAccessors`.
##
## Extending the section walker (cookbook):
##   1. Declare a new `PackageXxx[name: static string] = object` here.
##   2. Add a section-accessor template (`template xxx*(p: Package[name])`).
##   3. Teach `collectTopLevelBuildBindings` (or a sibling collector)
##      to walk that section keyword.
## No surgery on the `package` macro itself is required.

type
  Package*[name: static string] = object
    ## Generic compile-time handle for a producer package, parameterized
    ## by the static package name. Emitted as `const <name>* {.inject.}:
    ## Package["<name>"] = Package["<name>"]()` by the `package` macro
    ## when the body declares cross-project bindings AND the legacy
    ## per-package const shape is not already claimed by
    ## `wrapperCode`/`toolActionWrapperCode`.

  PackageBuild*[name: static string] = object
    ## Section handle for a package's `build:` block bindings. Per-binding
    ## accessor templates dispatch on this receiver type.

  PackageExecutables*[name: static string] = object
    ## Section handle reserved for future expansion.

  PackageLibraries*[name: static string] = object
    ## Section handle reserved for future expansion.

  PackageFiles*[name: static string] = object
    ## Section handle reserved for future expansion.

  PackageServices*[name: static string] = object
    ## Section handle reserved for future expansion.

## Section-accessor templates are emitted PER PACKAGE by `macros_b.nim`
## rather than as free generic templates here. The previous design
## (free `template build*[name: static string](p: Package[name])`)
## introduced an ambient `build` overload that collided with package-
## body `build:` section keywords during overload resolution of nested
## typed-tool calls like `buildNimUnittest.build(...)`. Per-package
## emission keeps `build` confined to the legacy `<TitleName>Package`
## receiver type, which is unique per package.
