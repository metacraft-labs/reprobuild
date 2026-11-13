## Moving the ``cli:`` language into the clispec library changed nothing an
## external tool sees.
##
## ``test_cs_m1_external_tool_argv_unchanged`` renders the external-tool
## surface of every in-tree ``cli:`` tool definition — the model the
## ``package`` macro builds (including reprobuild's extension: roles,
## outputs, optional outputs, ``removeBeforeRun``, sub-tools, dependency
## policy, entropy blessing, provider entry points), the argv each command
## renders with every parameter supplied, the interface artifact of each
## package, and the recorded calls and argv of a ``defineCliInterface``
## fixture — and compares it byte for byte with a golden capture.
##
## The golden (``tests/fixtures/cs-m1-external-tool-surface/surface.golden``)
## was captured on the tree BEFORE the move (3f90ff7dd), by this same
## renderer with one difference: the pre-move model had no ``ext`` slot, so
## the capture defined ``ext`` as the identity. It is a historical record,
## not a snapshot to refresh: if this test fails, the extraction changed
## behaviour. Change the golden only together with a deliberate change to a
## tool definition or to argv rendering, and say so in that commit.
##
## The negative controls prove the comparison can fail: a model with one
## flag's ``alias`` changed, and one with a flag's ``format`` changed, must
## both render differently from the golden, at that flag.
##
## No mocks: the stdlib packages are the real modules, registered by their
## real ``package`` blocks; argv is rendered by the engine's ``argvForCall``.

import std/[os, strutils, unittest]

import repro_project_dsl

import ./cs_m1_external_tool_surface

const goldenPath = currentSourcePath().parentDir().parentDir() /
  "fixtures" / "cs-m1-external-tool-surface" / "surface.golden"

proc firstDifference(expected, actual: string): string =
  ## The first line on which two renderings differ, for the failure report.
  let e = expected.splitLines()
  let a = actual.splitLines()
  for i in 0 ..< max(e.len, a.len):
    let el = if i < e.len: e[i] else: "<end of golden>"
    let al = if i < a.len: a[i] else: "<end of rendering>"
    if el != al:
      return "line " & $(i + 1) & ":\n  golden: " & el & "\n  actual: " & al
  ""

proc surfaceOf(packages: openArray[PackageDef]): string =
  renderExternalToolSurface(packages) & renderInterfaceFixtureSurface()

type FlagMutation = proc (param: var CliParamDef): bool {.nimcall.}

proc mutateFirstFlag(packages: var seq[PackageDef];
                     mutation: FlagMutation): string =
  ## Applies ``mutation`` to the first flag (in package-name order) it
  ## accepts, in every command that carries that flag, and returns
  ## ``"<package>/<flag>"``.
  var order: seq[int] = @[]
  for i in 0 ..< packages.len:
    order.add(i)
  for i in 0 ..< order.len:
    for j in i + 1 ..< order.len:
      if packages[order[j]].packageName < packages[order[i]].packageName:
        swap(order[i], order[j])
  for i in order:
    for exe in packages[i].executables.mitems:
      for cmd in exe.commands.mitems:
        for param in cmd.params.mitems:
          if param.kind == cpkFlag and mutation(param):
            let name = param.name
            for otherCmd in exe.commands.mitems:
              for other in otherCmd.params.mitems:
                if other.name == name and other.kind == cpkFlag:
                  discard mutation(other)
            return packages[i].packageName & "/" & name
  ""

suite "CS-M1: the clispec extraction leaves external tools unchanged":

  let golden = readFile(goldenPath)

  test "test_cs_m1_external_tool_argv_unchanged":
    let actual = surfaceOf(registeredPackages())
    # Vacuity guard: the rendering covers the stdlib tool set and the
    # ``defineCliInterface`` fixture, not an empty registry.
    check actual.count("\npackage ") + 1 >= 30
    check actual.contains("defineCliInterface \"cs-m1-iface\"")
    let difference = firstDifference(golden, actual)
    if difference.len > 0:
      checkpoint("the external-tool surface differs from the golden at " &
        difference)
    check actual == golden

  test "negative control: a changed alias makes the comparison fail":
    var packages = registeredPackages()
    let mutated = mutateFirstFlag(packages,
      proc (param: var CliParamDef): bool =
        if param.alias.len == 0: return false
        param.alias = param.alias & "-mutated"
        true)
    check mutated.len > 0
    let actual = surfaceOf(packages)
    check actual != golden
    let difference = firstDifference(golden, actual)
    checkpoint("mutated " & mutated & ": " & difference)
    check difference.contains("-mutated")

  test "negative control: a changed format makes the comparison fail":
    var packages = registeredPackages()
    let mutated = mutateFirstFlag(packages,
      proc (param: var CliParamDef): bool =
        if param.format != cafSeparate or param.nimType == "bool":
          return false
        param.format = cafEquals
        true)
    check mutated.len > 0
    let actual = surfaceOf(packages)
    check actual != golden
    let difference = firstDifference(golden, actual)
    checkpoint("mutated " & mutated & ": " & difference)
    check difference.contains("format=cafEquals")
