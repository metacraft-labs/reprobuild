## Test-Certificates TC-9a: ``planCertificateNodes`` reports the
## certificate-producing nodes a plan materializes, with the repository each
## belongs to (Test-Certificates.md §"Marking a node"). It is what HL-10 (the
## lock-update node) and TC-8e (issuance) ask of a plan.
##
## Through the built ``repro certificates plan``, on real projects in real
## git repositories:
##   1. the plan for ``unit-suite`` (``certificate "unit-suite"`` over an
##      aggregate of two edges) reports exactly that node, in the project's
##      repository. The project's ``test`` aggregate also groups a third edge,
##      so the implicit ``test`` marking is not materialized and not
##      reported;
##   2. the plan for one plain test edge reports nothing: it builds only part
##      of ``unit-suite``;
##   3. the ``unit-suite`` plan with ``--no-certify`` reports nothing;
##   4. a node marked inside a SIBLING project, planned from the consumer with
##      ``<sibling>:<name>``, is reported under the sibling's repository;
##   5. a marked edge reached only as a dependency of the selected edge is
##      materialized, and reported.
## No mock: real files, real ``git init`` repositories, a real provider
## compile and evaluation.

import std/[json, os, osproc, unittest]

import certificate_marking_fixture

proc gitInit(dir: string) =
  createDir(dir)
  let res = execCmdEx("git init -q " & quoteShell(dir))
  doAssert res.exitCode == 0, res.output

suite "t_plan_reports_its_certificate_producing_nodes":
  test "t_plan_reports_its_certificate_producing_nodes":
    let fx = newCertFixture("repro-tc9a-plan")
    defer: removeDir(fx.root)
    let workspace = fx.root / "ws"
    let project = workspace / "consumer"
    gitInit(project)
    writeCertProject(project, "consumer", ["unit", "integration", "e2e"],
      "    discard aggregate(\"test\", @[unit, integration, e2e])\n" &
      "    certificate \"unit-suite\", aggregate(\"unit-suite\", @[unit, integration])\n")

    let suitePlan = fx.certificatesPlan(project, ["unit-suite"])
    checkpoint($suitePlan)
    check suitePlan.len == 1
    check suitePlan[0]["name"].getStr() == "unit-suite"
    check suitePlan[0]["node"].getStr() == "unit-suite"
    check suitePlan[0]["implicit"].getBool() == false
    check suitePlan[0]["repository"].getStr() == project

    let plainEdge = fx.certificatesPlan(project, ["unit-out"])
    checkpoint($plainEdge)
    check plainEdge.len == 0

    check fx.certificatesPlan(project, ["unit-suite", "--no-certify"]).len == 0

    # The whole ``test`` aggregate materializes both marked nodes.
    let whole = fx.certificatesPlan(project, [])
    checkpoint($whole)
    check whole.names == @["unit-suite", "test"]

    # A sibling project, its own repository, marks a node; the consumer
    # plans it with ``<sibling>:<name>``.
    let sibling = workspace / "sibproj"
    gitInit(sibling)
    writeCertProject(sibling, "sibproj", ["lib", "libcheck"],
      "    certificate \"sib-suite\", aggregate(\"sib-suite\", @[lib, libcheck])\n")
    let fromSibling = fx.certificatesPlan(project, ["sibproj:sib-suite"])
    checkpoint($fromSibling)
    check fromSibling.len == 1
    check fromSibling[0]["name"].getStr() == "sib-suite"
    check fromSibling[0]["package"].getStr() == "sibproj"
    check fromSibling[0]["repository"].getStr() == sibling

  test "a marked edge reached as a dependency is materialized":
    let fx = newCertFixture("repro-tc9a-plan-dep")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    gitInit(project)
    # ``consume`` reads ``build/gen-out``, the output of ``gen``, so the
    # engine infers the dependency from the declared paths.
    writeCertProject(project, "depPkg", ["gen"],
      "    let consume = certTool(actionId = \"consume\",\n" &
      "      input = \"build/gen-out\",\n" &
      "      output = \"build/consume-out\",\n" &
      "      marker = \".repro/runs.log\")\n" &
      "    certificate \"generated\", gen\n")
    let viaDependency = fx.certificatesPlan(project, ["consume-out"])
    checkpoint($viaDependency)
    check viaDependency.names == @["generated"]
    check viaDependency[0]["nodeKind"].getStr() == "action"
    check viaDependency[0]["repository"].getStr() == project
