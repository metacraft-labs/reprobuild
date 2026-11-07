## Test-Certificates TC-9a: a certificate name shares the target namespace,
## so a collision is an error naming both declarations (Test-Certificates.md
## §"Marking a node").
##
## Three real projects, each driven through the built ``repro``:
##   1. ``certificate "x", b`` beside ``target "x", a``: the provider compile
##      fails, naming the certificate's line and the target's line;
##   2. two ``certificate "x"`` lines: the compile fails naming both lines;
##   3. a name only known when the body runs (``certificate name, b`` with
##      ``name = "x"`` computed) beside ``target "x", a``: the compile check
##      cannot see it, and the provider's evaluation refuses it instead,
##      naming the certificate's site.
## Control: the same project with the certificate over the target's own
## handle (``certificate "x", a``) builds and lists ``x``.
## No mock: real files, a real provider compile and evaluation.

import std/[os, strutils, unittest]

import certificate_marking_fixture

proc listOutput(fx: CertFixture; project: string):
    tuple[code: int; output: string] =
  fx.runRepro(project, ["certificates", "list", "--tool-provisioning=path"])

suite "t_certificate_name_collision_is_a_compile_error":
  test "certificate next to a target of the same name over another handle":
    let fx = newCertFixture("repro-tc9a-collide-target")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    writeCertProject(project, "certPkg", ["a", "b"],
      "    target \"x\", a\n" &
      "    certificate \"x\", b\n")
    let targetLine = lineOf(project / "repro.nim", "target \"x\"")
    let certLine = lineOf(project / "repro.nim", "certificate \"x\"")
    let res = fx.listOutput(project)
    checkpoint(res.output)
    check res.code != 0
    check "certificate name 'x' collides with the target 'x'" in res.output
    check ("repro.nim(" & $certLine & ",") in res.output
    check ("repro.nim(" & $targetLine & ",") in res.output

  test "the same certificate name declared twice":
    let fx = newCertFixture("repro-tc9a-collide-twice")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    writeCertProject(project, "certPkg", ["a", "b"],
      "    certificate \"x\", a\n" &
      "    certificate \"x\", b\n")
    let first = lineOf(project / "repro.nim", "certificate \"x\", a")
    let second = lineOf(project / "repro.nim", "certificate \"x\", b")
    let res = fx.listOutput(project)
    checkpoint(res.output)
    check res.code != 0
    check "certificate name 'x' is declared twice" in res.output
    check ("repro.nim(" & $first & ",") in res.output
    check ("repro.nim(" & $second & ",") in res.output

  test "a computed name is refused when the body runs":
    let fx = newCertFixture("repro-tc9a-collide-runtime")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    writeCertProject(project, "certPkg", ["a", "b"],
      "    target \"x\", a\n" &
      "    let computed = \"x\".toUpperAscii.toLowerAscii\n" &
      "    certificate computed, b\n")
    # ``toUpperAscii`` needs ``strutils``; the recipe imports it.
    writeFile(project / "repro.nim",
      "import std/strutils\n" & readFile(project / "repro.nim"))
    let certLine = lineOf(project / "repro.nim", "certificate computed")
    let res = fx.listOutput(project)
    checkpoint(res.output)
    check res.code != 0
    check "certificate name 'x' declared at" in res.output
    check ("repro.nim:" & $certLine) in res.output
    check "collides with the target 'x'" in res.output

  test "control: the certificate over the target's own handle":
    let fx = newCertFixture("repro-tc9a-collide-control")
    defer: removeDir(fx.root)
    let project = fx.root / "project"
    writeCertProject(project, "certPkg", ["a", "b"],
      "    target \"x\", a\n" &
      "    certificate \"x\", a\n")
    let res = fx.listOutput(project)
    checkpoint(res.output)
    check res.code == 0
    check "x  declared  certPkg  action a" in res.output
