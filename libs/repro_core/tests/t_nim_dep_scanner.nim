## Unit tests for ``repro_core/nim_dep_scanner`` — the Mode 3 Nim
## dependency scanner.
##
## The scanner contract is documented in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract". Each test below pins one slice of that contract:
##
##   * member discovery from a single ``repro.nim`` (single package)
##   * member discovery from a single project file that declares
##     multiple ``package`` blocks (the Mode 3 multi-package shape;
##     the DSL itself does not currently support compile-time
##     emission of two packages in one file, but the SCANNER works at
##     a separate level — it reads project files as text and produces
##     edges; that's what the unit test pins)
##   * stdlib-import suppression
##   * cross-package edge detection (A imports B → edge A→B)
##   * byte-deterministic re-render across runs
##   * ``renderScannedDepsFile`` header + body shape
##   * the legacy ``reprobuild.nim`` alias is still recognised by the
##     scanner (the resolver in ``project_file.nim`` is shared)
##
## The tests use ``getTempDir`` scratch dirs and remove them after
## each case so re-runs are clean.

import std/[os, strutils, tables, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-nim-dep-scanner-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "repro_core.nim_dep_scanner: member discovery":

  test "single package with one executable and one library member":
    let dir = makeScratch("single-package")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mode3Pilot:
  uses:
    "nim >=2.2 <3.0"

  library greet

  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "greet.nim", "proc greet*(): string = \"hi\"\n")
    writeFile(dir / "src" / "hello.nim", "import greet\necho greet()\n")
    let members = discoverMembers(dir)
    check members.len == 2
    # Result is sorted (package, member).
    check members[0].package == "mode3Pilot"
    check members[0].member == "greet"
    check members[1].package == "mode3Pilot"
    check members[1].member == "hello"
    removeDir(dir)

  test "two `package` blocks in one project file: scanner partitions members":
    # The scanner reads project files as text and partitions members
    # by the preceding ``package`` keyword. Independent of whether the
    # DSL macro layer can compile the same file: the marker collision
    # that historically prevented that has been fixed (see
    # ``libs/repro_project_dsl/tests/t_multi_package_macro.nim``) by
    # guarding the marker emission behind ``when not declared(...)``.
    # This test pins the scanner side of the contract; the DSL side is
    # pinned by the macro-layer test referenced above.
    let dir = makeScratch("multi-package")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package greetPkg:
  uses:
    "nim >=2.2 <3.0"
  library greet

package helloPkg:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "greet.nim", "proc greet*(): string = \"hi\"\n")
    writeFile(dir / "src" / "hello.nim", "import greet\necho greet()\n")
    let members = discoverMembers(dir)
    check members.len == 2
    # ``greetPkg.greet`` sorts before ``helloPkg.hello`` (lexicographic
    # on the (package, member) tuple).
    check members[0].package == "greetPkg"
    check members[0].member == "greet"
    check members[1].package == "helloPkg"
    check members[1].member == "hello"
    removeDir(dir)

  test "legacy reprobuild.nim filename is recognised (alias contract)":
    let dir = makeScratch("legacy-name")
    writeFile(dir / "reprobuild.nim", """
import repro_project_dsl

package legacyPkg:
  uses:
    "nim >=2.2 <3.0"
  executable main:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.nim", "echo \"hi\"\n")
    let members = discoverMembers(dir)
    check members.len == 1
    check members[0].package == "legacyPkg"
    check members[0].projectFile.endsWith("reprobuild.nim")
    removeDir(dir)

suite "repro_core.nim_dep_scanner: import extraction":

  test "extractImports picks up import / from / include forms":
    let text = """
import std/os
import strutils, tables
from std/strutils import contains
include "helper.nim"
import myproject/sub/module
"""
    let refs = extractImports(text)
    # ``import std/os`` → head ``std`` (we DO record stdlib imports;
    # the isStdlibImport filter runs later in scanWorkspace).
    check refs.len == 6
    check refs[0].moduleHead == "std"
    check refs[1].moduleHead == "strutils"
    check refs[2].moduleHead == "tables"
    check refs[3].moduleHead == "std"
    check refs[4].moduleHead == "helper"
    check refs[5].moduleHead == "myproject"

  test "isStdlibImport recognises common stdlib modules":
    check isStdlibImport("os")
    check isStdlibImport("strutils")
    check isStdlibImport("tables")
    check isStdlibImport("std")
    check not isStdlibImport("mypackage")
    check not isStdlibImport("greet")

  test "normaliseName collapses _, -, and case":
    check normaliseName("my_lib") == "mylib"
    check normaliseName("my-lib") == "mylib"
    check normaliseName("myLib") == "mylib"
    check normaliseName("MyLib") == "mylib"
    check normaliseName("MY_LIB") == "mylib"
    check normaliseName("greet") == "greet"

suite "repro_core.nim_dep_scanner: edge inference":

  test "executable importing a library in another workspace package emits one edge":
    let dir = makeScratch("two-pkg-edge")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package greetPkg:
  uses:
    "nim >=2.2 <3.0"
  library greet

package helloPkg:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "greet.nim", "proc greet*(): string = \"hi\"\n")
    writeFile(dir / "src" / "hello.nim", """
## hello binary — imports the library.
import greet

echo greet()
""")
    let scan = scanWorkspace(dir)
    check scan.members.len == 2
    check scan.edges.len == 1
    let edge = scan.edges[0]
    check edge.fromPackage == "helloPkg"
    check edge.toPackage == "greetPkg"
    check edge.evidence.contains("hello.nim")
    check edge.evidence.contains("import greet")
    removeDir(dir)

  test "stdlib-only imports produce no workspace edges":
    let dir = makeScratch("stdlib-only")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mainPkg:
  uses:
    "nim >=2.2 <3.0"
  executable main:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.nim", """
import std/[os, strutils, tables]
import std/json
from std/sequtils import zip

echo "no workspace deps"
""")
    let scan = scanWorkspace(dir)
    check scan.members.len == 1
    check scan.edges.len == 0
    removeDir(dir)

  test "self-imports (same package, different member) do NOT produce an edge":
    let dir = makeScratch("self-import")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package onePkg:
  uses:
    "nim >=2.2 <3.0"
  library greet
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "greet.nim", "proc greet*(): string = \"hi\"\n")
    writeFile(dir / "src" / "hello.nim", "import greet\necho greet()\n")
    let scan = scanWorkspace(dir)
    check scan.members.len == 2
    check scan.edges.len == 0
    removeDir(dir)

  test "import resolves by package-name when no member shares the name":
    let dir = makeScratch("by-package-name")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package myLib:
  uses:
    "nim >=2.2 <3.0"
  library mylib_umbrella

package myApp:
  uses:
    "nim >=2.2 <3.0"
  executable runner:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "mylib_umbrella.nim",
      "proc foo*(): string = \"bar\"\n")
    writeFile(dir / "src" / "runner.nim", """
## Import by package name (snake_case form) — should resolve to myLib.
import my_lib

echo "ran"
""")
    let scan = scanWorkspace(dir)
    check scan.edges.len == 1
    check scan.edges[0].fromPackage == "myApp"
    check scan.edges[0].toPackage == "myLib"
    removeDir(dir)

suite "repro_core.nim_dep_scanner: determinism":

  test "renderScannedDepsFile produces byte-identical output across runs":
    let dir = makeScratch("determinism")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package greetPkg:
  uses:
    "nim >=2.2 <3.0"
  library greet

package helloPkg:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "greet.nim", "proc greet*(): string = \"hi\"\n")
    writeFile(dir / "src" / "hello.nim", "import greet\necho greet()\n")
    let scan1 = scanWorkspace(dir)
    let render1 = renderScannedDepsFile(scan1.edges, "0.1.0",
      scan1.members, dir)
    let scan2 = scanWorkspace(dir)
    let render2 = renderScannedDepsFile(scan2.edges, "0.1.0",
      scan2.members, dir)
    check render1 == render2
    # Sanity: the rendered output is non-empty (carries the header)
    # and includes the expected edge.
    check render1.contains("DO NOT EDIT")
    check render1.contains("depends_on helloPkg: greetPkg")
    removeDir(dir)

  test "edges sort by (from, to, evidence) regardless of source-walk order":
    let dir = makeScratch("edge-sort")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package a:
  uses: "nim >=2.2 <3.0"
  library a_umbrella

package b:
  uses: "nim >=2.2 <3.0"
  library b_umbrella

package c:
  uses: "nim >=2.2 <3.0"
  executable c_main:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "a_umbrella.nim", "discard\n")
    writeFile(dir / "src" / "b_umbrella.nim", "discard\n")
    writeFile(dir / "src" / "c_main.nim", """
import b_umbrella
import a_umbrella
""")
    let scan = scanWorkspace(dir)
    check scan.edges.len == 2
    # Sorted by (from, to) — both from c, so secondary sort on to:
    # a (a_umbrella → a) before b.
    check scan.edges[0].toPackage == "a"
    check scan.edges[1].toPackage == "b"
    removeDir(dir)

suite "repro_core.nim_dep_scanner: rendered file shape":

  test "header carries DO NOT EDIT + engine version + scanner schema":
    let render = renderScannedDepsFile(@[], "9.9.9", @[], "")
    check render.contains("DO NOT EDIT")
    check render.contains("Engine version: 9.9.9")
    check render.contains("Scanner schema: " & ScannerSchemaVersion)
    check render.contains("(no inter-package dep edges discovered)")

  test "edge block emits one comment per evidence + grouped depends_on":
    let edges = @[
      DepEdge(fromPackage: "hello", toPackage: "greet",
        evidence: "src/hello.nim:5: import greet"),
      DepEdge(fromPackage: "hello", toPackage: "logFmt",
        evidence: "src/hello.nim:6: import log_fmt"),
    ]
    let render = renderScannedDepsFile(edges, "0.1.0", @[], "")
    check render.contains("# src/hello.nim:5: import greet")
    check render.contains("# src/hello.nim:6: import log_fmt")
    # Multi-dep emits the block form so Nim's parser accepts it
    # (inline comma after ``:`` triggers "invalid indentation").
    check render.contains("depends_on hello:")
    check render.contains("\n  greet\n")
    check render.contains("\n  logFmt\n")

  test "single-dep emits the inline form":
    let edges = @[
      DepEdge(fromPackage: "hello", toPackage: "greet",
        evidence: "src/hello.nim:5: import greet"),
    ]
    let render = renderScannedDepsFile(edges, "0.1.0", @[], "")
    check render.contains("depends_on hello: greet\n")

  test "two from-packages emit two separate depends_on lines":
    let edges = @[
      DepEdge(fromPackage: "alpha", toPackage: "core",
        evidence: "src/alpha.nim:1: import core"),
      DepEdge(fromPackage: "beta", toPackage: "core",
        evidence: "src/beta.nim:1: import core"),
    ]
    let render = renderScannedDepsFile(edges, "0.1.0", @[], "")
    check render.contains("depends_on alpha: core")
    check render.contains("depends_on beta: core")

suite "repro_core.nim_dep_scanner: --check parity":

  test "an up-to-date file matches the freshly-rendered output byte-for-byte":
    let dir = makeScratch("check-parity")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mainPkg:
  uses:
    "nim >=2.2 <3.0"
  executable main:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.nim", "echo \"hi\"\n")
    let scan = scanWorkspace(dir)
    let rendered = renderScannedDepsFile(scan.edges, "0.1.0",
      scan.members, dir)
    writeFile(dir / "repro.scanned-deps.nim", rendered)
    let onDisk = readExistingScannedDeps(dir / "repro.scanned-deps.nim")
    check onDisk == rendered
    removeDir(dir)

  test "missing scanned-deps file reads as empty string":
    let dir = makeScratch("missing-file")
    let onDisk = readExistingScannedDeps(dir / "repro.scanned-deps.nim")
    check onDisk.len == 0
    removeDir(dir)

  test "scannedDepsArePresent detects an include line":
    let dir = makeScratch("present-check")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package mainPkg:
  uses: "nim >=2.2 <3.0"
  executable main:
    discard

include "repro.scanned-deps.nim"
""")
    check scannedDepsArePresent(dir / "repro.nim")
    removeDir(dir)
