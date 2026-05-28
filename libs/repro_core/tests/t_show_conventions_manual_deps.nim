## Unit tests for ``repro_core/nim_dep_scanner`` —
## ``extractManualDependsOnFromText`` / ``..FromProjectFile``.
##
## These functions back the ``repro show-conventions`` CLI: they walk a
## ``repro.nim`` as text (no DSL evaluation) and surface the manual
## ``depends_on <pkg>: <dep>`` edges the user wrote by hand. The
## contract is documented in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Observability"
## (the manual-deps surface) and §"`depends_on` is a new DSL construct"
## (the recognised shapes).
##
## Recognised shapes — must match
## ``repro_project_dsl/macros_b.nim`` ``collectDependsOnEntries``:
##
##   ``depends_on hello: greet``                  inline single-dep
##   ``depends_on hello: greet, logFmt``          inline multi-dep
##   ``depends_on hello:`` + indented continuation block (one or many
##                                                 deps per line, comma-
##                                                 separated allowed)
##
## String-literal dep names (``"greet"``) parse the same as identifiers.

import std/[os, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-show-conventions-manual-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "nim_dep_scanner.extractManualDependsOn":

  test "inline single-dep form: ``depends_on app: lib``":
    let text = """
import repro_project_dsl

package appPkg:
  uses: "nim >=2.2 <3.0"
  executable app:
    discard

depends_on appPkg: libPkg
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 1
    check edges[0].fromPackage == "appPkg"
    check edges[0].toPackage == "libPkg"
    check edges[0].sourceLine > 0

  test "inline multi-dep form: ``depends_on a: x, y, z``":
    let text = "depends_on serverPkg: pluginRouter, pluginLogger, pluginAuth\n"
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 3
    check edges[0].fromPackage == "serverPkg"
    let names = @[edges[0].toPackage, edges[1].toPackage, edges[2].toPackage]
    check "pluginRouter" in names
    check "pluginLogger" in names
    check "pluginAuth" in names

  test "block form: indented body, one dep per line":
    let text = """
depends_on hello:
  greet
  logFmt
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 2
    let names = @[edges[0].toPackage, edges[1].toPackage]
    check "greet" in names
    check "logFmt" in names
    # The two deps should report different sourceLines, both within the
    # indented body.
    check edges[0].sourceLine != edges[1].sourceLine

  test "block form with comma-separated continuation lines":
    let text = """
depends_on hello:
  greet, logFmt
  bonus
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 3
    let names = @[edges[0].toPackage, edges[1].toPackage, edges[2].toPackage]
    check "greet" in names
    check "logFmt" in names
    check "bonus" in names

  test "string-literal deps are accepted (scanner-style spelling)":
    let text = """
depends_on hello: "greet", "logFmt"
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 2
    let names = @[edges[0].toPackage, edges[1].toPackage]
    check "greet" in names
    check "logFmt" in names

  test "non-matching identifiers starting with depends_on are skipped":
    # ``depends_onSomething`` is just an identifier, not our macro.
    let text = """
depends_onSomethingElse hello: greet
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 0

  test "trailing comments inside the dep list are stripped":
    let text = """
depends_on app:
  greet  # canonical greeting library
  logFmt
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 2
    let names = @[edges[0].toPackage, edges[1].toPackage]
    check "greet" in names
    check "logFmt" in names

  test "blank lines inside a block do NOT terminate the block":
    let text = """
depends_on app:
  greet

  logFmt
"""
    let edges = extractManualDependsOnFromText(text)
    check edges.len == 2

  test "FromProjectFile reads off disk":
    let dir = makeScratch("from-file")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package app:
  uses: "nim >=2.2 <3.0"
  executable app:
    discard

depends_on app: greet
depends_on app:
  bonus
""")
    let edges = extractManualDependsOnFromProjectFile(dir / "repro.nim")
    check edges.len == 2
    let names = @[edges[0].toPackage, edges[1].toPackage]
    check "greet" in names
    check "bonus" in names
    removeDir(dir)

  test "FromProjectFile on missing file returns empty seq":
    let edges = extractManualDependsOnFromProjectFile(
      getTempDir() / "does-not-exist-show-conv.nim")
    check edges.len == 0
