## Windows-System-Resources Phase G — profile-side tests for the
## action-edge half of the apply.
##
## The profile MACRO itself is exercised by the e2e fixtures under
## ``tests/e2e/m83/`` (which compile real profile files via
## ``nim c -r``); this suite covers the parts of Phase G that don't
## require macro invocation:
##
##   1. ``ProfileBuildAction`` mirror records the load-bearing fields
##      the apply driver consumes.
##   2. ``addProfileBuildAction`` push helper extracts argv from a
##      ``BuildActionDef`` whose ``call`` is an ``inlineExecCall(...)``
##      and pushes the flattened mirror onto a target seq.
##   3. ``profileInlineExecActionEdge`` assembles a
##      ``BuildActionDef`` from the spec § 2.3 example shape and
##      pushes the mirror via the same helper.
##   4. JSON emit / decode round-trips ``ProfileIntent.buildActions``.
##   5. ``isProfileActionEdgeCall`` macro predicate classifies a
##      synthetic AST shape against the closed allow-list.
##
## The integration test
## (``libs/repro_profile_compile/tests/t_smoke_phase_g_action_edges_integration.nim``)
## drives a real ``expandArchive.build(...)`` call through the helper
## + the apply dispatcher; the e2e test
## (``tests/e2e/m83/system_action_edges_phase_g.nim`` + the runner)
## drives the full macro + compile + apply path.

import std/[macros, strutils, unittest]

import repro_profile
import repro_project_dsl
import repro_dsl_stdlib/packages/expand_archive as expandArchive

# ---------------------------------------------------------------------------
# (1) ProfileBuildAction mirror shape.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase G — ProfileBuildAction shape":

  test "default-constructed values are inert":
    var ba: ProfileBuildAction
    check ba.id == ""
    check ba.argv.len == 0
    check ba.cwd == ""
    check ba.deps.len == 0
    check ba.inputs.len == 0
    check ba.outputs.len == 0
    check ba.commandStatsId == ""
    check ba.toolIdentityRefs.len == 0
    check ba.requiresElevation == false
    check ba.cacheable == false

  test "ProfileIntent has a buildActions field that starts empty":
    var p: ProfileIntent
    check p.buildActions.len == 0
    p.buildActions.add ProfileBuildAction(id: "x")
    check p.buildActions.len == 1
    check p.buildActions[0].id == "x"

# ---------------------------------------------------------------------------
# (2)–(3) Push helpers — ``addProfileBuildAction`` and
# ``profileInlineExecActionEdge``.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase G — push helpers":

  test "addProfileBuildAction extracts argv from inlineExecCall":
    resetBuildActionRegistry()
    let call = inlineExecCall(@["/bin/echo", "hello", "world"])
    let bad = buildAction(
      id = "echo-edge",
      call = call,
      outputs = @["/tmp/echo.out"],
      requiresElevation = true,
      cacheable = true,
      commandStatsId = "echoStats",
      toolIdentityRefs = @["/bin/echo"])
    var target: seq[ProfileBuildAction]
    addProfileBuildAction(target, bad)
    check target.len == 1
    let mir = target[0]
    check mir.id == "echo-edge"
    check mir.argv == @["/bin/echo", "hello", "world"]
    check mir.outputs == @["/tmp/echo.out"]
    check mir.requiresElevation
    check mir.cacheable
    check mir.commandStatsId == "echoStats"
    check mir.toolIdentityRefs == @["/bin/echo"]

  test "addProfileBuildAction preserves cwd from inlineExecCall":
    resetBuildActionRegistry()
    let call = inlineExecCall(@["./go"], cwd = "/var/tmp/work")
    let bad = buildAction(id = "go-edge", call = call)
    var target: seq[ProfileBuildAction]
    addProfileBuildAction(target, bad)
    check target.len == 1
    check target[0].cwd == "/var/tmp/work"

  test "addProfileBuildAction rejects non-inline-exec call shape":
    # A typed-tool call whose ``call`` isn't `reprobuild.builtin.exec`
    # (e.g. a subcommand call like the ones gcc / meson emit) is NOT
    # accepted in a profile ``resources:`` block — the spec's
    # action-edge surface is the inline-exec builtin only.
    resetBuildActionRegistry()
    let bogus = BuildActionDef(
      id: "wrong-call",
      call: PublicCliCall(
        packageName: "gcc",
        executableName: "cc",
        subcommand: "compile",
        arguments: @[]))
    var target: seq[ProfileBuildAction]
    expect ValueError:
      addProfileBuildAction(target, bogus)
    check target.len == 0

  test "profileInlineExecActionEdge assembles and pushes a mirror":
    resetBuildActionRegistry()
    var target: seq[ProfileBuildAction]
    profileInlineExecActionEdge(
      target = target,
      argv = @["C:\\actions-runner\\config.cmd", "--unattended"],
      address = "configureRunner",
      outputs = @["C:\\actions-runner\\.runner"],
      requiresElevation = true,
      toolIdentityRefs = @["C:\\actions-runner\\config.cmd"])
    check target.len == 1
    let mir = target[0]
    check mir.id == "configureRunner"
    check mir.argv == @["C:\\actions-runner\\config.cmd", "--unattended"]
    check mir.outputs == @["C:\\actions-runner\\.runner"]
    check mir.requiresElevation
    check mir.toolIdentityRefs == @["C:\\actions-runner\\config.cmd"]
    check mir.cacheable           # default true
    check mir.commandStatsId == "inlineExecCall"  # default

  test "profileInlineExecActionEdge derives an id from argv[0] when empty":
    resetBuildActionRegistry()
    var target: seq[ProfileBuildAction]
    profileInlineExecActionEdge(target = target,
      argv = @["/usr/bin/whoami"])
    check target.len == 1
    check target[0].id == "inlineExec:/usr/bin/whoami"

  test "profileInlineExecActionEdge rejects empty argv":
    resetBuildActionRegistry()
    var target: seq[ProfileBuildAction]
    expect ValueError:
      profileInlineExecActionEdge(target = target, argv = @[])
    check target.len == 0

# ---------------------------------------------------------------------------
# (4) JSON round-trip including buildActions.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase G — JSON round-trip with buildActions":

  test "empty buildActions emits an empty JSON array":
    var p: ProfileIntent
    p.name = "empty"
    let js = emitProfileIntentJson(p)
    check "\"buildActions\":[]" in js
    let dec = parseProfileIntentJson(js)
    check dec.buildActions.len == 0

  test "non-empty buildActions round-trips field-for-field":
    var p: ProfileIntent
    p.name = "phaseG-rt"
    p.buildActions.add ProfileBuildAction(
      id: "extractRunner",
      argv: @["powershell", "-Command", "Expand-Archive", "-Path",
        "C:\\runner.zip", "-DestinationPath", "C:\\actions-runner"],
      cwd: "",
      deps: @["runnerZip"],
      inputs: @["C:\\runner.zip"],
      outputs: @["C:\\actions-runner\\config.cmd"],
      commandStatsId: "expandArchive.eafZip",
      toolIdentityRefs: @["powershell"],
      requiresElevation: true,
      cacheable: true)
    p.buildActions.add ProfileBuildAction(
      id: "configureRunner",
      argv: @["C:\\actions-runner\\config.cmd", "--unattended",
        "--token", "@FILE:C:\\actions-runner-tokens\\mcl.token"],
      cwd: "C:\\actions-runner",
      deps: @["extractRunner"],
      inputs: @["C:\\actions-runner-tokens\\mcl.token"],
      outputs: @["C:\\actions-runner\\.runner"],
      commandStatsId: "inlineExecCall",
      toolIdentityRefs: @["C:\\actions-runner\\config.cmd"],
      requiresElevation: true,
      cacheable: true)
    let js = emitProfileIntentJson(p)
    let dec = parseProfileIntentJson(js)
    check dec.buildActions.len == 2
    check dec.buildActions[0].id == "extractRunner"
    check dec.buildActions[0].argv == p.buildActions[0].argv
    check dec.buildActions[0].outputs == p.buildActions[0].outputs
    check dec.buildActions[0].requiresElevation
    check dec.buildActions[0].commandStatsId == "expandArchive.eafZip"
    check dec.buildActions[0].toolIdentityRefs == @["powershell"]
    check dec.buildActions[1].id == "configureRunner"
    check dec.buildActions[1].cwd == "C:\\actions-runner"
    check dec.buildActions[1].deps == @["extractRunner"]
    # The @FILE: literal rides through the JSON unmodified — the
    # spec's audit-redaction is downstream of this codec.
    var sawAtFile = false
    for a in dec.buildActions[1].argv:
      if a.startsWith("@FILE:"):
        sawAtFile = true
    check sawAtFile

# ---------------------------------------------------------------------------
# (5) Macro-side closed allow-list predicate.
# ---------------------------------------------------------------------------

# The predicate is a `proc` (not a macro) but operates on `NimNode`s.
# We feed it nodes synthesised at compile time inside a helper macro
# that returns the predicate's verdict as a `bool` literal.

macro classifyShape(stmt: untyped): bool =
  newLit(isProfileActionEdgeCall(stmt))

suite "Windows-System-Resources Phase G — closed allow-list predicate":

  test "accepts expandArchive.build(...) (typed-tool, in allow-list)":
    check classifyShape(expandArchive.build(archive = "x", destination = "y"))

  test "accepts bare inlineExecCall(...)":
    check classifyShape(inlineExecCall(argv = @["x"]))

  test "rejects fsSystemFile(...) (live-state resource)":
    check not classifyShape(fsSystemFile(path = "/etc/hosts.d/x"))

  test "rejects windowsService(...) (live-state resource)":
    check not classifyShape(windowsService(name = "x"))

  test "rejects gcc.build(...) (typed-tool, NOT in allow-list)":
    # `gcc.build` exists in repro_dsl_stdlib but its `call` shape is
    # a subcommand call, not an inline-exec call — so it doesn't
    # belong inside a profile `resources:` block. The macro must
    # reject this WITHOUT a runtime ValueError (which would only
    # surface at apply time, much later).
    check not classifyShape(gcc.build(target = "x"))

  test "rejects a wholly unknown <ident>.build(...) call":
    check not classifyShape(unknown_tool.build(foo = "x"))

  test "rejects a bare ident that isn't on the bare-call allow-list":
    check not classifyShape(buildAction(id = "x"))
    check not classifyShape(inlineExecCallNotEvenReal(argv = @["x"]))
