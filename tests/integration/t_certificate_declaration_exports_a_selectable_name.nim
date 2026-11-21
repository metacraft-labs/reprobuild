## Test-Certificates TC-9a: ``certificate "<name>", <handle>`` exports
## ``<name>`` as a target name (Test-Certificates.md §"Marking a node").
##
## A real project declares ``certificate "unit-suite"`` over an aggregate of
## two edges, beside a third edge the aggregate leaves out. Through the built
## ``repro``:
##   * ``repro build unit-suite`` runs exactly the two member edges;
##   * ``repro certificates list`` names ``unit-suite`` with its node and its
##     declaration line, read from the stored graph;
##   * the name also works over an edge handle the target-export table did
##     not already name (``certificate "single", lone``), and selects that
##     edge;
##   * removing the declarations makes ``unit-suite`` unresolvable with the
##     ordinary ``unknown_target`` diagnostic.
## No mock: the fixture is real files, a real provider compile and a real
## build (see ``certificate_marking_fixture``).

import std/[json, os, strutils, unittest]

import certificate_marking_fixture

suite "t_certificate_declaration_exports_a_selectable_name":
  test "t_certificate_declaration_exports_a_selectable_name":
    let fx = newCertFixture("repro-tc9a-select")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    writeCertProject(project, "certPkg", ["unit", "integration", "lone"],
      "    certificate \"unit-suite\", aggregate(\"unit-suite\", @[unit, integration])\n" &
      "    certificate \"single\", lone\n")
    let declLine = lineOf(project / "repro.nim", "certificate \"unit-suite\"")

    # The declared name selects the aggregate: both members run, the
    # unmarked third edge does not.
    let built = fx.runRepro(project, ["build", "unit-suite",
      "--tool-provisioning=path", "--daemon=off"])
    checkpoint(built.output)
    check built.code == 0
    check fileExists(project / "build" / "unit-out")
    check fileExists(project / "build" / "integration-out")
    check not fileExists(project / "build" / "lone-out")

    # ``repro certificates list`` prints the name, its node and its site.
    let listed = fx.certificatesList(project)
    checkpoint($listed)
    var sawSuite = false
    var sawSingle = false
    for entry in listed:
      case entry["name"].getStr()
      of "unit-suite":
        sawSuite = true
        check entry["nodeKind"].getStr() == "target"
        check entry["node"].getStr() == "unit-suite"
        check entry["implicit"].getBool() == false
        check entry["package"].getStr() == "certPkg"
        check entry["source-file"].getStr().endsWith("repro.nim")
        check entry["source-line"].getInt() == declLine
      of "single":
        sawSingle = true
        check entry["nodeKind"].getStr() == "action"
        check entry["node"].getStr() == "lone"
      else:
        discard
    check sawSuite
    check sawSingle
    # The text form names it too.
    let text = fx.runRepro(project, ["certificates", "list",
      "--tool-provisioning=path"])
    check text.code == 0
    check "unit-suite  declared  certPkg  target unit-suite" in text.output

    # ``certificate "single", lone`` exported a NEW name over an edge.
    let single = fx.runRepro(project, ["build", "single",
      "--tool-provisioning=path", "--daemon=off"])
    checkpoint(single.output)
    check single.code == 0
    check fileExists(project / "build" / "lone-out")

    # Without the declarations the name is unknown, reported the ordinary
    # way.
    writeCertProject(project, "certPkg", ["unit", "integration", "lone"], "")
    let unknown = fx.runRepro(project, ["build", "unit-suite",
      "--tool-provisioning=path", "--daemon=off"])
    checkpoint(unknown.output)
    check unknown.code != 0
    check "unknown_target" in unknown.output
    check "unit-suite" in unknown.output
    check fx.certificatesList(project).len == 0
