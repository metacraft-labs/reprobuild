## Package-Model.md §"Package names": two package names whose sanitized forms
## are the same Nim identifier cannot both be declared in one registry; the
## `package` macro rejects the second with a diagnostic naming both.
##
## Every refusal is an out-of-process `nim check` (never `compiles(...)`, which
## is vacuous for `package` blocks, see `service_block_compile_probe.nim`). The
## discriminator is the message text: without the check, the second
## declaration in one module fails only with `redefinition of`, which names
## neither package, and across two modules it compiles.

import std/[os, osproc, strutils, unittest]
import repro_project_dsl/selector_names
import ./service_block_compile_probe

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()
    .parentDir()

proc checkModules(files: openArray[(string, string)]; main, tag: string):
    ServiceCompileProbeResult =
  let scratch = repoRoot() / "build" /
    ("package-collision-probe-" & tag & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  for (name, body) in files:
    writeFile(scratch / name, body)
  let (output, code) = execCmdEx(
    "nim check --hints:off --colors:off -d:reproProviderMode " &
      quoteShell(scratch / main), workingDir = repoRoot())
  ServiceCompileProbeResult(ok: code == 0, output: output)

proc moduleSource(name: string): string =
  "import repro_project_dsl\n\npackage \"" & name & "\":\n" &
    "  defaultToolProvisioning \"path\"\n"

const Importer = "import mod_a, mod_b\n"

suite "package names sharing a Nim identifier":

  test "two modules imported by one recipe are refused, naming both":
    let probe = checkModules([("mod_a.nim", moduleSource("foo-bar")),
      ("mod_b.nim", moduleSource("foobar")), ("recipe.nim", Importer)],
      "recipe.nim", "two-modules")
    check not probe.ok
    check probe.mentions("\"foobar\"")
    check probe.mentions("\"foo-bar\"")
    check probe.mentions("same Nim identifier")

  test "two packages in one module are refused, naming both":
    let probe = checkRecipeSource(
      moduleSource("foo-bar") & "\npackage fooBar:\n  defaultToolProvisioning \"path\"\n",
      "one-module")
    check not probe.ok
    check probe.mentions("same Nim identifier")
    check probe.mentions("\"foo-bar\"")
    check probe.mentions("\"fooBar\"")

  test "distinct names are accepted (control)":
    let probe = checkModules([("mod_a.nim", moduleSource("foo-bar")),
      ("mod_b.nim", moduleSource("foo-baz")), ("recipe.nim", Importer)],
      "recipe.nim", "control-two")
    check probe.ok
    let single = checkRecipeSource(
      moduleSource("foo-bar") & "\npackage fooBaz:\n  defaultToolProvisioning \"path\"\n",
      "control-one")
    check single.ok

  test "the same name imported twice is not a collision":
    let probe = checkModules([("mod_a.nim", moduleSource("foo-bar")),
      ("mod_b.nim", moduleSource("foo-bar")), ("recipe.nim", Importer)],
      "recipe.nim", "same-name")
    check not probe.mentions("same Nim identifier")
    check not probe.mentions("redefinition")

  test "no two stdlib packages share a key":
    let dir = repoRoot() / "libs" / "repro_dsl_stdlib" / "src" /
      "repro_dsl_stdlib" / "packages"
    var seen: seq[(string, string)]
    var count = 0
    for path in walkDirRec(dir):
      if not path.endsWith(".nim"): continue
      for line in readFile(path).splitLines:
        if line.startsWith("package ") and line.strip.endsWith(":"):
          var n = line["package ".len .. ^1].strip
          n = n[0 ..< n.len - 1].strip
          n = n.strip(chars = {'"', '`'})
          inc count
          let key = packageIdentifierKey(n)
          for (k, other) in seen:
            check not (k == key and other != n)
          seen.add((key, n))
    check count > 100
