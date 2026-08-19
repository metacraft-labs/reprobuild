## The producer-side runtime library declaration.
##
## A package that provides a shared library declares WHERE the loader finds it,
## because the producing package is the only party that knows its own prefix
## layout. The consuming half already existed as `runtimeDeps:`; this is the
## other end of the same contract.
##
## Why not reuse `library <name>:`. Its `exportedPath` is a Nim SOURCE
## directory — what a consumer threads onto `nim c --path:` (types.nim) — and
## its `kind:` describes a library the package BUILDS from source. Neither says
## anything about a prebuilt `.dll` arriving inside a provisioned prefix.
## Pointing `exportedPath` at `Library/bin` would tell Nim consumers to add a
## DLL directory to their source path. The catalog entry for clingo carried a
## comment saying exactly this, and saying there was no correct way to declare
## it. There is now.
##
## The declaration is per (cpu, os) slice for the same reason `tarball` entries
## are: the directory follows the PROVISIONING SOURCE, so one package is
## `Library/bin` from conda-forge win-64 and `lib` from nixpkgs.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/prefix_layout

package runtimeLibPkg:
  # The real clingo case, spelled with the layout vocabulary rather than
  # pasted strings.
  runtimeLibrary "clingo", dir = runtimeLibDir(plConda),
    cpu = "x86_64", os = "windows"
  runtimeLibrary "clingo", dir = runtimeLibDir(plUnix), os = "linux"
  runtimeLibrary "clingo", dir = runtimeLibDir(plUnix), os = "macos"

package runtimeLibAnyPkg:
  # No cpu/os: applies to every host.
  runtimeLibrary "ubiquitous", dir = "lib"

package runtimeLibMultiPkg:
  # A package may provide more than one library on the same platform.
  runtimeLibrary "first", dir = "lib"
  runtimeLibrary "second", dir = "lib64"

suite "runtimeLibrary declarations reach the registry":
  test "every slice is recorded, unfiltered":
    let libs = registeredRuntimeLibraries("runtimeLibPkg")
    check libs.len == 3

  test "the layout vocabulary is evaluated, not spelled":
    let libs = registeredRuntimeLibraries("runtimeLibPkg")
    check libs[0].dir == "Library/bin"
    check libs[1].dir == "lib"

  test "name, cpu and os round-trip":
    let libs = registeredRuntimeLibraries("runtimeLibPkg")
    check libs[0].name == "clingo"
    check libs[0].cpu == "x86_64"
    check libs[0].os == "windows"
    # An omitted cpu stays empty rather than becoming a stray literal.
    check libs[1].cpu == ""
    check libs[1].os == "linux"

  test "declarations carry a source location":
    let libs = registeredRuntimeLibraries("runtimeLibPkg")
    check libs[0].sourceFile.len > 0
    check libs[0].sourceLine > 0

  test "a package that declares none returns the empty seq":
    # The accessor must be safe to call from code that does not know whether
    # the package opted in.
    check registeredRuntimeLibraries("noSuchPackageEverDeclared").len == 0

suite "host selection picks the right slice":
  test "windows host gets the conda layout":
    let sel = selectRuntimeLibraries("runtimeLibPkg", "x86_64", "windows")
    check sel.len == 1
    check sel[0].dir == "Library/bin"

  test "linux host gets the unix layout":
    let sel = selectRuntimeLibraries("runtimeLibPkg", "x86_64", "linux")
    check sel.len == 1
    check sel[0].dir == "lib"

  test "darwin and macos are aliases":
    # The DSL accepts both spellings, so the matcher must too — otherwise a
    # recipe written with one spelling silently matches no host.
    let viaMacos = selectRuntimeLibraries("runtimeLibPkg", "x86_64", "macos")
    let viaDarwin = selectRuntimeLibraries("runtimeLibPkg", "x86_64", "darwin")
    check viaMacos.len == 1
    check viaDarwin.len == 1
    check viaMacos[0].dir == viaDarwin[0].dir

  test "a cpu mismatch excludes the slice":
    # The windows entry is pinned to x86_64, so an aarch64 windows host must
    # NOT pick it up — silently loading an x86_64 DLL is the failure mode
    # windows/ensure-clingo.ps1 rejects explicitly.
    let sel = selectRuntimeLibraries("runtimeLibPkg", "aarch64", "windows")
    check sel.len == 0

  test "an unconstrained declaration matches every host":
    for (cpu, os) in [("x86_64", "windows"), ("aarch64", "linux"),
                      ("x86_64", "macos")]:
      check selectRuntimeLibraries("runtimeLibAnyPkg", cpu, os).len == 1

  test "all matching libraries are returned, not just the first":
    let sel = selectRuntimeLibraries("runtimeLibMultiPkg", "x86_64", "linux")
    check sel.len == 2
    check sel[0].name == "first"
    check sel[1].name == "second"
