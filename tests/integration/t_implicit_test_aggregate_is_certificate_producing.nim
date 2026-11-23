## Test-Certificates TC-9a, operator decision D15: what a plain
## ``repro test`` builds — the node the selector ``test`` resolves to — is
## implicitly ``certificate "test"`` (Test-Certificates.md §"Marking a
## node").
##
## Through the built ``repro``, on real projects:
##   1. edges and an ``aggregate("test", ...)`` over them, no certificate
##      declaration: ``repro certificates list`` shows ``test`` as implicit,
##      and the plan for a plain ``repro test`` returns the ``test`` aggregate
##      under the name ``test``;
##   2. ``--no-certify`` empties that plan;
##   3. the same project with ``certificate "test"`` declared over a
##      narrower aggregate: no collision, ``test`` is listed once, as
##      declared, and the plan returns the narrower handle instead;
##   4. a project with no ``test`` name has no implicit marking, and a plain
##      ``repro test`` there is the ordinary unknown-target error (it is
##      ``repro build test``; nothing gathers every edge instead);
##   5. a project with no ``test`` target whose edge has the implicit name
##      ``test``: a plain ``repro test`` builds that edge, and that edge is
##      what is marked.
## No mock: real files, a real provider compile and evaluation.

import std/[json, os, strutils, unittest]

import certificate_marking_fixture

suite "t_implicit_test_aggregate_is_certificate_producing":
  test "t_implicit_test_aggregate_is_certificate_producing":
    let fx = newCertFixture("repro-tc9a-implicit")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    writeCertProject(project, "certPkg", ["unit", "integration"],
      "    discard aggregate(\"test\", @[unit, integration])\n")

    let listed = fx.certificatesList(project)
    checkpoint($listed)
    check listed.len == 1
    check listed[0]["name"].getStr() == "test"
    check listed[0]["implicit"].getBool()
    check listed[0]["nodeKind"].getStr() == "target"
    check listed[0]["node"].getStr() == "test"
    let text = fx.runRepro(project, ["certificates", "list",
      "--tool-provisioning=path"])
    check "test  implicit  certPkg  target test" in text.output

    # A plain ``repro test`` plans ``test``; its aggregate is the node.
    let plain = fx.certificatesPlan(project, [])
    checkpoint($plain)
    check plain.len == 1
    check plain[0]["name"].getStr() == "test"
    check plain[0]["node"].getStr() == "test"
    check plain[0]["implicit"].getBool()
    check fx.certificatesPlan(project, ["--no-certify"]).len == 0

    # An explicit ``certificate "test"`` over a narrower aggregate replaces
    # the implicit handle, without a collision.
    writeCertProject(project, "certPkg", ["unit", "integration"],
      "    discard aggregate(\"test\", @[unit, integration])\n" &
      "    certificate \"test\", aggregate(\"fast\", @[unit])\n")
    let replaced = fx.certificatesList(project)
    checkpoint($replaced)
    check replaced.len == 1
    check replaced[0]["name"].getStr() == "test"
    check not replaced[0]["implicit"].getBool()
    check replaced[0]["node"].getStr() == "fast"
    let narrowed = fx.certificatesPlan(project, [])
    checkpoint($narrowed)
    check narrowed.len == 1
    check narrowed[0]["name"].getStr() == "test"
    check narrowed[0]["node"].getStr() == "fast"
    check fx.certificatesPlan(project, ["--no-certify"]).len == 0

    # No ``test`` target, no implicit marking.
    writeCertProject(project, "certPkg", ["unit", "integration"], "")
    check fx.certificatesList(project).len == 0

    # A plain ``repro test`` with no ``test`` target does not fall back to
    # every edge: it is ``repro build test``, which fails with the ordinary
    # unknown-target error. Nothing runs, so nothing is marked.
    let unknown = fx.runRepro(project, ["test", "--tool-provisioning=path"])
    checkpoint(unknown.output)
    check unknown.code != 0
    check "no build target matches 'test'" in unknown.output
    # The plan for it is refused the same way: there is no plan to mark.
    let unknownPlan = fx.runRepro(project, ["certificates", "plan",
      "--tool-provisioning=path"])
    checkpoint(unknownPlan.output)
    check unknownPlan.code == 2
    check "test" in unknownPlan.output

    # But whatever the selector ``test`` does resolve to is what a plain
    # ``repro test`` builds, so that is what is marked: here an edge whose
    # implicit name (its output's basename) is ``test``, with no ``test``
    # target anywhere.
    writeCertProject(project, "certPkg", ["unit", "integration"],
      "    let named = certTool(actionId = \"named-test\",\n" &
      "      input = \"src/unit.txt\", output = \"build/test\",\n" &
      "      marker = \".repro/runs.log\")\n")
    let byName = fx.certificatesList(project)
    checkpoint($byName)
    check byName.len == 1
    check byName[0]["name"].getStr() == "test"
    check byName[0]["implicit"].getBool()
    check byName[0]["nodeKind"].getStr() == "action"
    check byName[0]["node"].getStr() == "named-test"
    let byNamePlan = fx.certificatesPlan(project, [])
    checkpoint($byNamePlan)
    check byNamePlan.len == 1
    check byNamePlan[0]["node"].getStr() == "named-test"
    let ran = fx.runRepro(project, ["test", "--tool-provisioning=path"])
    checkpoint(ran.output)
    check ran.code == 0
    let runs = readFile(project / ".repro" / "runs.log")
    check "build/test" in runs
    check "unit-out" notin runs
