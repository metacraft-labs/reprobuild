## Moving the ``cli:`` language into the clispec library changed nothing an
## external tool sees, and nothing since has changed it by accident.
##
## ``test_cs_m1_external_tool_argv_unchanged`` renders the external-tool
## surface of every in-tree ``cli:`` tool definition -- the model the
## ``package`` macro builds (including reprobuild's extension: roles,
## outputs, optional outputs, ``removeBeforeRun``, sub-tools, dependency
## policy, input-check policy, entropy blessing, provider entry points), the
## argv each command renders with every parameter supplied, the command
## surface of each package's interface artifact read back through the codec,
## and the recorded calls and argv of a ``defineCliInterface`` fixture -- and
## compares it byte for byte with a golden capture.
##
## The golden (``tests/fixtures/cs-m1-external-tool-surface/surface.golden``)
## was first captured on the tree BEFORE the move (3f90ff7dd), by this same
## renderer with one difference: the pre-move model had no ``ext`` slot, so
## the capture defined ``ext`` as the identity. If this test fails, a tool's
## command line, its build-graph declarations or the argv rendering changed.
## Change the golden only together with a deliberate change to a tool
## definition or to argv rendering, and say so in that commit and in the list
## below. The rendering leaves out source line numbers and the digest of the
## whole interface artifact (see ``cs_m1_external_tool_surface.nim``), so an
## edit that does not touch a command line does not fail this test.
##
## Maintenance: nothing runs this test for you when you change a tool. It is
## not part of ``just lint``, the suite that does run it is not run for a
## commit to ``agents``, and no rule selects the tests that guard a changed
## path, so a change under ``libs/repro_dsl_stdlib/`` (a ``cli:`` block, a
## tool's build-graph declarations), under ``cli_extension.nim`` /
## ``packageLiteral``, or to ``argvForCall`` reaches ``agents`` without it.
## That is how the golden went stale for two days in November 2026, after
## three deliberate tool changes. Run it yourself for such a change:
## ``nim c -r tests/unit/t_cs_m1_external_tool_argv_unchanged.nim``.
##
## Deliberate changes since the capture:
##
## * clispec now reads ``required`` on a positional (it used to drop it), so
##   the four ``pos args is seq[string], ..., required = false`` declarations
##   (git, mktemp, node, sh) record ``required=false``, as they always said.
##   Their argv did not change.
## * ``cargo-nextest`` gained a ``cli:`` block (269fd0da9, "add a thin cargo
##   edge"): ``cargo_nextest.nextest(run = true, ...)`` is a typed call, sized
##   with ``--test-threads``. A new package; no existing argv changed.
## * ``nim`` gained the optional ``skipUserCfg`` flag (``--skipUserCfg``,
##   9442575a2, "harden helper dependency lists"): test-helper binaries are
##   built with it. It is rendered only when a caller sets it.
## * ``gcc``, ``clang`` and ``ar`` declare ``inputCheckPolicy hybrid``
##   (dfd3ba20c, "share content-checked compile and archive edges by
##   default"). Not an argv change; the field was added to the model then,
##   and is rendered since the golden was refreshed.
## * The refresh that recorded the three entries above also dropped source
##   line numbers and the whole-artifact interface digest from the rendering
##   (both had moved on edits that change no command line: the envelope
##   version bump of 0b52b4b4c moved every package's digest), and renders the
##   artifact's decoded command surface instead.
## * ``gcc`` and ``clang`` gained the optional ``soname`` flag
##   (``-Wl,-soname,<value>``, spelled as ``zig cc``'s already is), so
##   ``gccLink`` / ``clangLink`` bake a shared library's full SONAME into its
##   ``DT_SONAME``, as ``LinkOptions.soname`` always promised. It is
##   rendered only when a caller sets it: a shared link with a SONAME.
##
## The negative controls prove the comparison can fail: a model with one
## flag's ``alias`` changed, one with a flag's ``format`` changed, one with a
## command's input-check policy changed, and one with an extra package must
## each render differently from the golden, at that place. The positive
## control proves the rendering ignores what it claims to ignore: every
## source line moved, the rendering is still the golden.
##
## No mocks: the stdlib packages are the real modules, registered by their
## real ``package`` blocks; argv is rendered by the engine's ``argvForCall``;
## the interface artifact goes through the real codec.

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

  test "negative control: a changed input-check policy makes the comparison fail":
    var packages = registeredPackages()
    var mutated = ""
    block search:
      for pkg in packages.mitems:
        for exe in pkg.executables.mitems:
          for cmd in exe.commands.mitems:
            if cmd.ext.inputCheckPolicy == acfpUnstated:
              cmd.ext.inputCheckPolicy = acfpChecksum
              mutated = pkg.packageName & "/" & exe.exportName
              break search
    check mutated.len > 0
    let actual = surfaceOf(packages)
    check actual != golden
    let difference = firstDifference(golden, actual)
    checkpoint("mutated " & mutated & ": " & difference)
    check difference.contains("inputCheckPolicy=acfpChecksum")

  test "negative control: a new package with a command makes the comparison fail":
    var packages = registeredPackages()
    var added = PackageDef()
    for pkg in packages:
      if pkg.executables.len > 0 and pkg.executables[0].commands.len > 0:
        added = pkg
        break
    check added.packageName.len > 0
    # Sorts after every stdlib package, so the first difference is the new
    # package itself and not a shifted neighbour.
    added.packageName = "zz-cs-m1-new-tool"
    packages.add(added)
    let actual = surfaceOf(packages)
    check actual != golden
    let difference = firstDifference(golden, actual)
    checkpoint("added zz-cs-m1-new-tool: " & difference)
    check difference.contains("zz-cs-m1-new-tool")

  test "positive control: moving every source line leaves the rendering unchanged":
    var packages = registeredPackages()
    var moved = 0
    for pkg in packages.mitems:
      pkg.sourceLine += 1000
      for exe in pkg.executables.mitems:
        exe.sourceLine += 1000
        for cmd in exe.commands.mitems:
          cmd.sourceLine += 1000
          for td in cmd.ext.typedOutputs.mitems:
            td.sourceLine += 1000
          for param in cmd.params.mitems:
            param.sourceLine += 1000
            inc moved
    check moved > 100
    let actual = surfaceOf(packages)
    let difference = firstDifference(golden, actual)
    if difference.len > 0:
      checkpoint("moved source lines changed the rendering at " & difference)
    check actual == golden
