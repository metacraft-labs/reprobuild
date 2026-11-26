## NPC-M9 verification `test_npc_m9_non_nimble_siblings_keep_directory_policy`
## (review finding R1; Nimble-Package-Catalog.md NPC-AREQ27, its third
## bullet: "A dependency that is not a `nimble:` package keeps Reprobuild's
## existing sibling policy"; Nim-Package-Path-Handling.md § 1).
##
## A codetracer-shaped project: `uses:` names `isonim`, `isonim-tui` and
## `codetracer-trace-format-nim`, Reprobuild workspace packages (not
## `nimble:` packages), each a sibling directory of that name with a
## `src/`, and `nimble:results`, a locked catalog package, beside which is a
## directory named `results`. No develop override is recorded and no
## workspace declares anything. `repro.paths` names `../isonim/src`,
## `../isonim-tui/src` and `../codetracer-trace-format-nim/src`, as before
## the catalog's develop mode existed; the catalog package's line is its
## store tree, and the directory named `results` is on no line.
##
## Falsifying mutation (recorded in the plan): removing the directory-name
## block for every dependency (the part-A tree before R1) drops the three
## lines and fails the test.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures
import ./nimble_m9_fixtures

const CodetracerShaped = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package app:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "gcc"
    "sh"
    "mkdir"
    "isonim"
    "isonim-tui"
    "codetracer-trace-format-nim"
$USES
  build:
    discard nim.nimRepropathsConfig()
    discard nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      parallelBuild = 1)
    discard shell(
      command = "mkdir -p build && ./build/bin/app",
      actionId = "app.run",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
"""

proc siblingRecipe(package: string): string =
  "import repro_dsl_stdlib\n\npackage " & package & ":\n  library " &
    package & ":\n    discard\n"

suite "NPC-M9: a dependency that is not a nimble: package keeps its sibling":
  test "isonim, isonim-tui and codetracer-trace-format-nim reach repro.paths":
    var c = newCliWorld("m9-non-nimble")
    let f = newFixture("m9-non-nimble", c.mirrorRoutes)
    let src = f.package("arnetheduck/nim-results.git", @[nimbleFile("results"),
      file("src/results.nim", nimbleModule("CATALOG-M9"))])
    c.mirror.putSource(src)
    let rec = f.recordOf("results", src, "v1.0.0")
    discard c.w.publish(@[f.envelope("results", @[rec], src)], daysAgo(1),
      "generation 1", extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let dir = c.w.writeCliProject("app", @[("results", "")],
      "import results\nwriteFile(\"build/app-out.txt\", stamp())\n",
      CodetracerShaped)
    let env = cliEnv(c.w, f)
    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    check locked.rc == 0

    let parent = parentDir(dir)
    for (name, package) in [("isonim", "isonim"), ("isonim-tui", "isonim_tui"),
        ("codetracer-trace-format-nim", "codetracer_trace_format_nim")]:
      createDir(parent / name / "src")
      writeFile(parent / name / "repro.nim", siblingRecipe(package))
      writeFile(parent / name / "src" / (package & ".nim"),
        "const marker* = \"" & name & "\"\n")
    # A directory named like the catalog package, holding a module that
    # would shadow it.
    createDir(parent / "results" / "src")
    writeFile(parent / "results" / "src" / "results.nim",
      nimbleModule("DIRECTORY-M9"))
    check not fileExists(dir / ".repro" / "develop-overrides.toml")

    let built = runRepro(env, dir, BuildArgs)
    checkpoint built.output
    check built.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "CATALOG-M9"
    let paths = readFile(dir / "repro.paths")
    checkpoint paths
    for name in ["isonim", "isonim-tui", "codetracer-trace-format-nim"]:
      check ("switch(\"path\", \"" & expandFilename(parent / name / "src") &
        "\")") in paths
    check (expandFilename(parent / "results")) notin paths
    check src.tree in paths
    check "# develop override" notin paths
