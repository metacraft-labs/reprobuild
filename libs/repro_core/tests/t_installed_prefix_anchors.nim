## An image built as an installed prefix for another machine
## (`-d:reproInstalledPrefix`, set by this file's `.nim.cfg` as reprobuild's
## `config.nims` sets it under a zig target) carries no compiled-in source
## path of its build host (reprobuild-pm Distribution-And-Packaging.md §5.3,
## decision B, approved by Zahary Karadjov, 2026-11-03).
##
## Measured on the armv7 prefix images before these anchors went: about 130
## lines per engine image named `libs/...` of the build tree, and the
## builder-path gate refuses every one. What replaces them is the installed
## layout, which `source_root` already ranks ahead of the compiled path.

import std/[strutils, unittest]

import repro_core/source_root
import repro_core/relocation

suite "an installed-prefix image names no build-tree path":
  test "the compiled-in source root is empty, and its candidate says why":
    check CompiledSourceRoot == ""
    let last = reprobuildSourceRootCandidates()[^1]
    check last.path == ""
    check "installed prefix" in last.skipReason

  test "a DSL source site is named by its import path":
    check importPathName("/b/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/" &
      "packages/zig.nim") == "repro_dsl_stdlib/packages/zig.nim"
    check importPathName("C:\\b\\libs\\x\\src\\x\\y.nim") == "x/y.nim"
    check importPathName("/b/recipes/repro.nim") == "repro.nim"
    const here = recipeSourceName(currentSourcePath())
    check here == "t_installed_prefix_anchors.nim"
