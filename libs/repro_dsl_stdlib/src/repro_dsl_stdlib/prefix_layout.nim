## Where things live inside a realized prefix, named once.
##
## A recipe that needs the shared-library directory of a provisioned package
## has to know a layout convention: `lib` for nixpkgs, `Library/bin` for
## conda-forge win-64, the prefix root for many Windows zips. Spelling those out
## per declaration means every recipe re-derives the same fact, and gets it
## wrong in the same way — which is how `clingo.dll` came to be arranged for by
## hand in five separate places.
##
## This module names the conventions instead. A package writes
## `runtimeLibDir(plConda)` rather than `"Library/bin"`, and the layout is
## defined once, here, with the reasoning attached.
##
## ## The axis is the provisioning source, not the operating system
##
## `plConda` is not "Windows". conda-forge uses the `Library/` prefix on win-64
## specifically, while its Linux packages are ordinary `bin/`+`lib/`. nixpkgs is
## `bin/`+`lib/` everywhere. A bare Windows zip is often flat. So the layout
## follows *where the package came from*, with the platform only correlating —
## which is why these are named after distributions and shapes rather than after
## operating systems.
##
## ## The distinction that actually bites: loadable vs linkable
##
## On Unix one directory holds both: `lib/libfoo.so` is what the linker resolves
## against and what the loader opens at run time.
##
## On Windows they are different directories. The loadable `foo.dll` sits beside
## the executables in `bin/`, while the import library `foo.lib` sits in `lib/`.
## A recipe that reaches for "the lib directory" to find a DLL finds nothing —
## and this is not hypothetical: `clingo.dll` is at `Library/bin/clingo.dll` in
## the conda-forge win-64 package, which is exactly why `runtimeLibDir` and
## `linkLibDir` are separate functions here rather than one `libDir`.
##
## These are `func`s over a plain enum, so they fold at compile time and can be
## written directly in a DSL setter — `exportedPath: runtimeLibDir(plConda)`.
## Nothing about them is special-cased by the macros; the DSL accepts them
## because it splices the expression and lets the compiler evaluate it.

type
  PrefixLayout* = enum
    ## The shape of a realized prefix, named after the source that produces it.
    plUnix
      ## `bin/`, `lib/`, `include/` — nixpkgs, and most Unix tarballs.
    plConda
      ## `Library/bin/`, `Library/lib/`, `Library/include/` — conda-forge
      ## win-64. The `Library/` prefix is a win-64 convention; conda's Linux
      ## packages use `plUnix`.
    plWindowsTree
      ## `bin/`, `lib/` with Windows loader rules — a Windows archive that
      ## keeps the usual directory names. Differs from `plUnix` in that the
      ## loadable DLL lives in `bin/`, not `lib/`.
    plFlat
      ## Everything at the prefix root — common for small Windows zips.

func binDir*(layout: PrefixLayout): string =
  ## Where executables live, relative to the realized prefix.
  case layout
  of plUnix: "bin"
  of plConda: "Library/bin"
  of plWindowsTree: "bin"
  of plFlat: "."

func runtimeLibDir*(layout: PrefixLayout): string =
  ## Where the LOADABLE shared library lives — the `.so` / `.dylib` / `.dll`
  ## the dynamic loader opens at run time. This is the directory a launcher
  ## must make searchable.
  ##
  ## Note it is the BIN directory on every Windows-shaped layout. That is the
  ## Windows rule, not an inconsistency: `clingo.dll` really is at
  ## `Library/bin/clingo.dll` in the conda-forge package.
  case layout
  of plUnix: "lib"
  of plConda: "Library/bin"
  of plWindowsTree: "bin"
  of plFlat: "."

func linkLibDir*(layout: PrefixLayout): string =
  ## Where the LINKABLE library lives — the `.a` / `.lib` import library the
  ## linker resolves against. Same directory as `runtimeLibDir` on Unix;
  ## different on Windows.
  case layout
  of plUnix: "lib"
  of plConda: "Library/lib"
  of plWindowsTree: "lib"
  of plFlat: "."

func includeDir*(layout: PrefixLayout): string =
  ## Where public headers live.
  case layout
  of plUnix: "include"
  of plConda: "Library/include"
  of plWindowsTree: "include"
  of plFlat: "."

func pkgConfigDir*(layout: PrefixLayout): string =
  ## Where `.pc` files live. Under the LINK library directory on every layout
  ## that has one, matching pkg-config's own convention.
  case layout
  of plUnix: "lib/pkgconfig"
  of plConda: "Library/lib/pkgconfig"
  of plWindowsTree: "lib/pkgconfig"
  of plFlat: "."

func sharedLibName*(layout: PrefixLayout; stem: string): string =
  ## The file name of a shared library given its stem — `clingo` becomes
  ## `libclingo.so` on a Unix layout and `clingo.dll` on a Windows-shaped one.
  ##
  ## Deliberately keyed off the LAYOUT rather than off `defined(windows)`: what
  ## matters is the shape of the prefix being described, which for a
  ## cross-compilation or a staged image is not necessarily the host.
  ##
  ## macOS is not distinguishable from Linux by layout alone — both are
  ## `plUnix` — so a recipe that needs `.dylib` should name the file itself.
  ## Encoding a guess here would be worse than declining to.
  case layout
  of plUnix: "lib" & stem & ".so"
  of plConda, plWindowsTree, plFlat: stem & ".dll"
