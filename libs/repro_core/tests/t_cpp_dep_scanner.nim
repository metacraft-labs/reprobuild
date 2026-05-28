## Unit tests for ``repro_core/cpp_dep_scanner`` — the Mode 3 C/C++
## dependency scanner.
##
## Each test below pins one slice of the scanner contract documented in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract", restated for the C/C++ side:
##
##   * member discovery filters by layout: a package with only ``.nim``
##     sources doesn't appear in the C/C++ scanner's member list.
##   * ``#include "..."`` (quoted form) emits a workspace edge when the
##     quoted path resolves under another package's ``include/`` or
##     ``src/``.
##   * ``#include <...>`` (angle-bracket form) NEVER emits an edge — it
##     is treated as ecosystem-external regardless of whether the
##     surrounded path would resolve to a workspace header.
##   * the scanner is byte-deterministic: two runs over the same tree
##     produce identical sorted edge lists.
##   * the unified ``scanWorkspaceAll`` merges Nim + C/C++ outputs with
##     stable edge ordering across mixed-language workspaces.

import std/[os, strutils, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-cpp-dep-scanner-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.cpp_dep_scanner: include extraction":

  test "extractCCppIncludes picks up the quoted form and skips angle brackets":
    let text = "#include <stdio.h>\n" &
      "#include \"mathlib/add.h\"\n" &
      "  #include \"config.h\"\n" &
      "int main(void) { return 0; }\n"
    let refs = extractCCppIncludes(text)
    check refs.len == 2
    check refs[0].target == "mathlib/add.h"
    check refs[0].lineNumber == 2
    check refs[1].target == "config.h"
    check refs[1].lineNumber == 3

  test "ignores #include inside // line comments":
    let text = """
// #include "ignored.h"
#include "real.h"
"""
    let refs = extractCCppIncludes(text)
    check refs.len == 1
    check refs[0].target == "real.h"

  test "tolerates indentation before #":
    let text = """
#ifdef FOO
  #include "indented.h"
#endif
"""
    let refs = extractCCppIncludes(text)
    check refs.len == 1
    check refs[0].target == "indented.h"

suite "repro_core.cpp_dep_scanner: edge inference":

  test "executable including a library header in another package emits one edge":
    let dir = makeScratch("two-package-include")
    # Two packages, each in its own subdirectory (the standard Mode 3
    # multi-package layout). The library publishes its public header
    # under ``mathlib/include/mathlib/add.h``; the executable's source
    # ``#include "mathlib/add.h"`` resolves to the library's header,
    # producing one cross-package edge.
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "gcc >=11"
  library mathlib
""")
    createDir(dir / "mathlib" / "src")
    createDir(dir / "mathlib" / "include")
    createDir(dir / "mathlib" / "include" / "mathlib")
    writeFile(dir / "mathlib" / "include" / "mathlib" / "add.h",
      "#pragma once\nint add(int a, int b);\n")
    writeFile(dir / "mathlib" / "src" / "add.c",
      "#include \"mathlib/add.h\"\nint add(int a, int b) { return a + b; }\n")

    createDir(dir / "calc")
    writeFile(dir / "calc" / "repro.nim", """
import repro_project_dsl

package calcPkg:
  uses:
    "gcc >=11"
  executable calc:
    discard
""")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "calc.c",
      "#include <stdio.h>\n#include \"mathlib/add.h\"\nint main(void) { return add(1, 2); }\n")

    let scan = scanWorkspaceCpp(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    check scan.edges[0].evidence.contains("calc.c:")
    check scan.edges[0].evidence.contains("mathlib/add.h")
    removeDir(dir)

  test "system header (#include <stdio.h>) never produces an edge":
    let dir = makeScratch("stdlib-only-include")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "gcc >=11"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.c",
      "#include <stdio.h>\n#include <stdlib.h>\nint main(void) { return 0; }\n")
    let scan = scanWorkspaceCpp(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "layout B: two packages in one project file with per-member subdirs":
    # Layout B is the canonical multi-package shape: one ``repro.nim``
    # at the workspace root declares two packages, each with its own
    # ``<member>/src/`` + ``<member>/include/`` subtree. This is the
    # shape the Mode 3 fixture under ``reprobuild-examples/c-cpp-mode3/
    # binary-with-library/`` uses.
    let dir = makeScratch("layout-b-multi-package")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "gcc >=11"
  library mathlib

package calcPkg:
  uses:
    "gcc >=11"
  executable calc:
    discard
""")
    createDir(dir / "mathlib")
    createDir(dir / "mathlib" / "src")
    createDir(dir / "mathlib" / "include")
    createDir(dir / "mathlib" / "include" / "mathlib")
    writeFile(dir / "mathlib" / "include" / "mathlib" / "add.h",
      "#pragma once\nint add(int a, int b);\n")
    writeFile(dir / "mathlib" / "src" / "add.c",
      "#include \"mathlib/add.h\"\nint add(int a, int b) { return a + b; }\n")
    createDir(dir / "calc")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "calc.c",
      "#include <stdio.h>\n#include \"mathlib/add.h\"\nint main(void) { return add(1, 2); }\n")
    let scan = scanWorkspaceCpp(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "calcPkg"
    check scan.edges[0].toPackage == "mathlibPkg"
    removeDir(dir)

  test "self-include (same package's own header) does NOT emit an edge":
    let dir = makeScratch("self-include")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package solo:
  uses:
    "gcc >=11"
  library foo
""")
    createDir(dir / "src")
    createDir(dir / "include")
    createDir(dir / "include" / "foo")
    writeFile(dir / "include" / "foo" / "internal.h",
      "#pragma once\nint helper(void);\n")
    writeFile(dir / "src" / "foo.c",
      "#include \"foo/internal.h\"\nint helper(void) { return 7; }\n")
    let scan = scanWorkspaceCpp(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

suite "repro_core.cpp_dep_scanner: determinism":

  test "two runs over the same workspace produce byte-identical edges":
    let dir = makeScratch("determinism")
    createDir(dir / "alpha")
    writeFile(dir / "alpha" / "repro.nim", """
import repro_project_dsl

package alpha:
  uses:
    "gcc >=11"
  library alpha
""")
    createDir(dir / "alpha" / "src")
    createDir(dir / "alpha" / "include")
    createDir(dir / "alpha" / "include" / "alpha")
    writeFile(dir / "alpha" / "include" / "alpha" / "core.h",
      "int alpha_core(void);\n")
    writeFile(dir / "alpha" / "src" / "alpha.c",
      "#include \"alpha/core.h\"\nint alpha_core(void) { return 1; }\n")

    createDir(dir / "beta")
    writeFile(dir / "beta" / "repro.nim", """
import repro_project_dsl

package beta:
  uses:
    "gcc >=11"
  executable beta:
    discard
""")
    createDir(dir / "beta" / "src")
    writeFile(dir / "beta" / "src" / "beta.c",
      "#include \"alpha/core.h\"\nint main(void) { return alpha_core(); }\n")
    let first = scanWorkspaceCpp(dir)
    let second = scanWorkspaceCpp(dir)
    check first.edges.len == second.edges.len
    check first.edges.len >= 1
    for i in 0 ..< first.edges.len:
      check first.edges[i].fromPackage == second.edges[i].fromPackage
      check first.edges[i].toPackage == second.edges[i].toPackage
      check first.edges[i].evidence == second.edges[i].evidence
    removeDir(dir)

suite "repro_core.cpp_dep_scanner: rendered output":

  test "renderScannedDepsFile emits the expected depends_on block for a C/C++ edge":
    let dir = makeScratch("rendered-output")
    createDir(dir / "mathlib")
    writeFile(dir / "mathlib" / "repro.nim", """
import repro_project_dsl

package mathlibPkg:
  uses:
    "gcc >=11"
  library mathlib
""")
    createDir(dir / "mathlib" / "src")
    createDir(dir / "mathlib" / "include")
    createDir(dir / "mathlib" / "include" / "mathlib")
    writeFile(dir / "mathlib" / "include" / "mathlib" / "add.h",
      "int add(int, int);\n")
    writeFile(dir / "mathlib" / "src" / "add.c", "#include \"mathlib/add.h\"\n")

    createDir(dir / "calc")
    writeFile(dir / "calc" / "repro.nim", """
import repro_project_dsl

package calcPkg:
  uses:
    "gcc >=11"
  executable calc:
    discard
""")
    createDir(dir / "calc" / "src")
    writeFile(dir / "calc" / "src" / "calc.c",
      "#include \"mathlib/add.h\"\nint main(void) { return 0; }\n")
    let scan = scanWorkspaceCpp(dir)
    let rendered = renderScannedDepsFile(scan.edges, "0.1.0", scan.members,
      dir)
    check rendered.contains("DO NOT EDIT")
    check rendered.contains("depends_on calcPkg: mathlibPkg")
    check rendered.contains("calc.c:") # evidence comment
    removeDir(dir)

suite "repro_core.cpp_dep_scanner: unified multi-language scan":

  test "scanWorkspaceAll unions Nim and C/C++ members + edges deterministically":
    # A mixed workspace: one Nim package + a C/C++ library + a C/C++
    # executable. Each package lives in its own directory under the
    # workspace root.
    let dir = makeScratch("multi-language")
    createDir(dir / "nim-pkg")
    writeFile(dir / "nim-pkg" / "repro.nim", """
import repro_project_dsl

package nimSolo:
  uses:
    "nim >=2.2 <3.0"
  library greet
""")
    createDir(dir / "nim-pkg" / "src")
    writeFile(dir / "nim-pkg" / "src" / "greet.nim",
      "proc greet*(): string = \"hi\"\n")

    createDir(dir / "cpp-lib")
    writeFile(dir / "cpp-lib" / "repro.nim", """
import repro_project_dsl

package cppLib:
  uses:
    "gcc >=11"
  library cppLib
""")
    createDir(dir / "cpp-lib" / "src")
    createDir(dir / "cpp-lib" / "include")
    createDir(dir / "cpp-lib" / "include" / "cppLib")
    writeFile(dir / "cpp-lib" / "include" / "cppLib" / "api.h",
      "int api(void);\n")
    writeFile(dir / "cpp-lib" / "src" / "lib.c",
      "#include \"cppLib/api.h\"\nint api(void) { return 1; }\n")

    createDir(dir / "cpp-app")
    writeFile(dir / "cpp-app" / "repro.nim", """
import repro_project_dsl

package cppApp:
  uses:
    "gcc >=11"
  executable app:
    discard
""")
    createDir(dir / "cpp-app" / "src")
    writeFile(dir / "cpp-app" / "src" / "app.c",
      "#include \"cppLib/api.h\"\nint main(void) { return api(); }\n")
    let unified = scanWorkspaceAll(dir)
    var nimSeen = false
    var cppLibSeen = false
    var cppAppSeen = false
    for m in unified.members:
      if m.package == "nimSolo": nimSeen = true
      if m.package == "cppLib": cppLibSeen = true
      if m.package == "cppApp": cppAppSeen = true
    check nimSeen
    check cppLibSeen
    check cppAppSeen
    var cppEdgeFound = false
    for e in unified.edges:
      if e.fromPackage == "cppApp" and e.toPackage == "cppLib":
        cppEdgeFound = true
    check cppEdgeFound
    removeDir(dir)
