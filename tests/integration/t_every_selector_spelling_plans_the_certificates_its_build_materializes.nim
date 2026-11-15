## Test-Certificates TC-9a / TC-8e: the certificate plan resolves a selector
## exactly as the build it describes does, and ``repro test`` names every
## selector that certifies nothing, with the reason.
##
## A selector spelled with ``.`` or ``/`` is a path / fragment selector
## (CLI/build.md §"Target Selection"). Two such spellings used to plan no
## certificate at all although the build ran the marked work:
##
##   1. ``.#<collection>#<member>`` (the collection-member shorthand the
##      build resolves, Deferred Item D5). The plan's own resolver did not
##      know the form, called it an unknown target, and ``repro test`` fell
##      back to a plain build: the marked member ran and nothing was said
##      about its certificate.
##   2. A path with no ``#<name>`` fragment (``.``, ``repro.nim``, a project
##      directory). The build lowers the whole graph minus the ``test`` /
##      ``bench`` / ``lint`` collections; the plan was handed no name and
##      materialized nothing, so a marked node the build ran was never
##      planned.
##
## And a selector that really selects only unmarked work must not end
## silently: ``repro test`` prints ``no certificate for '<selector>'`` with
## the reason (reprobuild-pm issue
## 2026-11-08-a-dotted-or-slashed-test-target-certifies-nothing.md).
##
## No mock: real projects in real ``git init`` repositories, driven through
## the built ``repro``, so every selector goes through the real provider
## compile, evaluation and lowering.

import std/[json, os, osproc, strutils, unittest]

import certificate_marking_fixture

proc gitInit(dir: string) =
  createDir(dir)
  let res = execCmdEx("git init -q " & quoteShell(dir))
  doAssert res.exitCode == 0, res.output

proc writeProject(project: string) =
  ## ``gen`` is ordinary build work (no collection) marked ``generated``;
  ## ``unit`` and ``e2e`` are the ``test`` collection's members, and only
  ## ``unit`` is marked (``unit-only``).
  writeCertProject(project, "selpkg", ["gen", "unit", "e2e"],
    "    discard collect(\"test\", @[unit, e2e])\n" &
    "    certificate \"generated\", gen\n" &
    "    certificate \"unit-only\", unit\n")

suite "t_every_selector_spelling_plans_the_certificates_its_build_materializes":
  test "a collection-member selector plans its member's certificate":
    let fx = newCertFixture("repro-cert-member")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    gitInit(project)
    writeProject(project)

    # The build accepts the spelling and runs exactly the member.
    let build = fx.runRepro(project, ["build", ".#test#unit",
      "--tool-provisioning=path"])
    checkpoint("repro build .#test#unit:\n" & build.output)
    check build.code == 0
    let ran = readFile(project / ".repro" / "runs.log")
    check "build/unit-out" in ran
    check "build/e2e-out" notin ran

    # The plan resolves it the same way: the marked member is planned.
    let member = fx.certificatesPlan(project, [".#test#unit"])
    checkpoint($member)
    check member.names == @["unit-only"]
    check member[0]["nodeKind"].getStr() == "action"
    # ``sameFile``, not ``==``: on macOS the temporary directory is reached
    # through the ``/var`` -> ``/private/var`` symlink, and the plan reports
    # the repository by its resolved spelling.
    check sameFile(member[0]["repository"].getStr(), project)

    # The unmarked member plans nothing, and is not an unknown target.
    check fx.certificatesPlan(project, [".#test#e2e"]).len == 0

  test "a path selector without a fragment plans what the whole build runs":
    let fx = newCertFixture("repro-cert-path")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    gitInit(project)
    writeProject(project)

    # ``repro build .`` builds ``gen`` and leaves the ``test`` collection
    # out (Generic Build Exclude Rules).
    let build = fx.runRepro(project, ["build", ".", "--tool-provisioning=path"])
    checkpoint("repro build .:\n" & build.output)
    check build.code == 0
    let ran = readFile(project / ".repro" / "runs.log")
    check "build/gen-out" in ran
    check "build/unit-out" notin ran

    for spelling in [".", "repro.nim", project]:
      let plan = fx.certificatesPlan(project, [spelling])
      checkpoint(spelling & ": " & $plan)
      check plan.names == @["generated"]

    # From the parent directory, ``project`` is a slashed spelling.
    let fromParent = fx.certificatesPlan(fx.root, ["project/repro.nim"])
    checkpoint($fromParent)
    check fromParent.names == @["generated"]

  test "repro test names a selector that certifies nothing, with the reason":
    let fx = newCertFixture("repro-cert-say-why")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    gitInit(project)
    writeProject(project)

    let unmarked = fx.runRepro(project, ["test", ".#test#e2e",
      "--tool-provisioning=path"])
    checkpoint("repro test .#test#e2e:\n" & unmarked.output)
    check unmarked.code == 0
    check "build/e2e-out" in readFile(project / ".repro" / "runs.log")
    check "no certificate for '.#test#e2e'" in unmarked.output
    check "selects no certificate-producing node" in unmarked.output

    # A selector that does reach a marked node is not reported as one that
    # selects none (this project is in no workspace, so issuance itself is
    # refused for that reason, which the run states).
    let marked = fx.runRepro(project, ["test", ".#test#unit",
      "--tool-provisioning=path"])
    checkpoint("repro test .#test#unit:\n" & marked.output)
    check marked.code == 0
    check "no certificate for '.#test#unit'" notin marked.output
    check "repro test: no certificate" in marked.output

    # Two selectors, one certifying and one not: only the second is named.
    let mixed = fx.runRepro(project, ["test", ".#test#unit", ".#test#e2e",
      "--tool-provisioning=path"])
    checkpoint("repro test .#test#unit .#test#e2e:\n" & mixed.output)
    check mixed.code == 0
    check "no certificate for '.#test#e2e'" in mixed.output
    check "no certificate for '.#test#unit'" notin mixed.output
