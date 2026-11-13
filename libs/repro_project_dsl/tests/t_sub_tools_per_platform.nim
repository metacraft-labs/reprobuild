## A typed tool can declare sub-tools per platform: `subTools` inside a
## `when defined(<platform>)` directly under `cli:`.
##
## A tool's sub-tools can differ by platform -- `nim c` runs `clang` on
## macOS and `gcc` elsewhere -- and declaring the other platform's tool is
## not harmless: sub-tools come before an edge's own references on its
## `PATH`, so the extra directory can shadow the tool the edge names. The
## `cli:` grammar therefore lets `subTools` sit in a platform `when`, and
## only the branch that holds for the platform being compiled contributes.
##
## The cases check the parsed tool (every command carries the selected
## list) and an edge recorded through the generated wrapper.

import std/[unittest]

import repro_project_dsl

package tSubToolsPerPlatform:
  executable platformTool:
    cli:
      subTools "everywhere"
      when defined(macosx):
        subTools "macos-only"
      elif not defined(posix):
        subTools "non-posix-only"
      else:
        subTools "other-posix"
      subcmd "run":
        pos input is string,
          role = input,
          position = 0

const expected =
  when defined(macosx): @["everywhere", "macos-only"]
  elif not defined(posix): @["everywhere", "non-posix-only"]
  else: @["everywhere", "other-posix"]

suite "per-platform sub-tools":

  test "only the branch that holds for this platform is declared":
    var found = false
    for pkg in registeredPackages():
      if pkg.packageName != "tSubToolsPerPlatform":
        continue
      found = true
      check pkg.executables.len == 1
      check pkg.executables[0].commands.len == 1
      for cmd in pkg.executables[0].commands:
        check cmd.ext.subTools == expected
    check found

  test "an edge the wrapper records carries the selected sub-tools":
    resetBuildActionRegistry()
    let act = tSubToolsPerPlatform.run(input = "in.txt")
    var refs: seq[string]
    for registered in registeredBuildActions():
      if registered.id == act.id:
        refs = registered.subToolRefs
    check refs == expected
