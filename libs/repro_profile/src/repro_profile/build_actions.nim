## Windows-System-Resources Phase G: bridge module that pushes the
## ``BuildActionDef`` returned by a typed-tool ``build`` call (or a bare
## ``inlineExecCall(...)`` wrapped in ``buildAction``) onto a
## ``ProfileIntent.buildActions`` seq as a ``ProfileBuildAction`` mirror.
##
## The profile DSL macro (in ``./macros.nim``) rewrites every action-
## edge call inside a ``resources:`` block to wrap its return value with
## ``addProfileBuildAction(targetSeq, ...)``. The helper extracts the
## fields the apply driver needs to assemble a
## ``repro_build_engine.BuildAction`` and route the edge through
## ``runBuild`` with the elevation broker hook attached.
##
## This module is the single seam in ``repro_profile`` that depends on
## ``repro_project_dsl`` (for the ``BuildActionDef`` type and its
## ``call.arguments`` codec); the rest of ``repro_profile`` stays
## standalone. Carrying the dep here (rather than in ``./types.nim``)
## keeps the JSON emitter / hardware-probe / disk-tools paths off the
## DSL runtime — they only see the flattened ``ProfileBuildAction``
## mirror.
##
## ## What gets extracted
##
## ``inlineExecCall(argv)`` packages ``argv`` as a single
## ``cliArgSeq("argv", argv, ...)`` ``PublicCliArg`` with the elements
## joined by ``"\x1f"`` (the codec separator the engine's inline-exec
## lowering uses). We decode that here so the profile-side payload
## carries the resolved argv as a plain ``seq[string]`` without
## requiring the apply driver to re-decode the codec.
##
## Other fields map straight through: ``id``, ``deps``, ``inputs``,
## ``outputs``, ``commandStatsId``, ``toolIdentityRefs``,
## ``requiresElevation``, ``cacheable``.
##
## ## What does NOT get extracted
##
## ``BuildActionDef`` carries fields that don't apply to a profile-side
## action edge: ``pool`` / ``poolUnits`` / ``cpuMilli`` / ``memoryBytes``
## (the apply driver runs a single-edge graph with bypassed run quota),
## ``depfile`` / ``dynamicDepsFile`` (the inline-exec builtin doesn't
## emit them), ``env`` (the elevation broker manages the env at fork
## time), ``cacheEntryIdentity`` / ``publishToBinaryCache`` (binary-
## cache publish is not in Phase G's scope), ``targetNames`` /
## ``typedOutputs`` (these are the build-graph target-export tagging
## fields the home-style apply path doesn't consume). A future phase
## can plumb additional fields through by extending
## ``ProfileBuildAction`` and the extraction below.
##
## ## Failure modes
##
## The helper raises ``ValueError`` when the ``BuildActionDef`` shape is
## not a ``reprobuild.builtin.exec`` call (the only shape a profile-
## scope action edge takes — every typed-tool ``build`` proc lowers via
## ``inlineExecCall`` and bare ``inlineExecCall(...)`` is the other
## accepted form). Returning early-on-shape-mismatch instead of
## silently dropping the action edge is the Phase A–F bar: silent
## fallbacks are the reviewer's red line.

import std/strutils

import repro_project_dsl

import ./types

# ---------------------------------------------------------------------------
# argv decode from the ``inlineExecCall`` ``PublicCliCall`` shape.
# ---------------------------------------------------------------------------

const InlineExecPackageName = "reprobuild.builtin"
  ## The package name ``inlineExecCall(argv)`` stamps on the
  ## ``PublicCliCall``. The engine's ``lowerGraphAction`` matches on
  ## ``(packageName, executableName) == ("reprobuild.builtin", "exec")``
  ## to take the inline-exec short-circuit branch; we re-use the same
  ## sentinel here so a future codec migration touches one place.

const InlineExecExecutableName = "exec"

const InlineExecArgvSeparator = '\x1f'
  ## ``cliArgSeq`` joins its values with the ASCII US (unit-separator)
  ## byte. The engine's ``lowerGraphAction`` splits on the same byte
  ## to recover ``argv``; we mirror that decoding here.

proc decodeInlineExecArgv(call: PublicCliCall): seq[string] =
  ## Recover the argv from a ``PublicCliCall`` produced by
  ## ``inlineExecCall(argv)``. Raises ``ValueError`` when the call's
  ## ``(package, executable)`` doesn't match the inline-exec shape, or
  ## when no ``argv`` argument is present.
  ##
  ## A ``cliArgSeq`` whose source ``argv`` was empty encodes as a
  ## ``PublicCliArg`` with an EMPTY ``encodedValue``; we map that to an
  ## empty ``seq[string]`` so the round-trip is loss-free.
  if call.packageName != InlineExecPackageName or
     call.executableName != InlineExecExecutableName:
    raise newException(ValueError,
      "addProfileBuildAction: action's call is not a " &
      "reprobuild.builtin.exec inline-exec call " &
      "(got " & call.packageName & "." & call.executableName & "); " &
      "only typed-tool .build(...) calls that lower via " &
      "inlineExecCall(argv) and bare inlineExecCall(...) calls are " &
      "accepted inside a profile resources: block")
  for arg in call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split(InlineExecArgvSeparator)
  raise newException(ValueError,
    "addProfileBuildAction: inline-exec call carries no argv argument")

proc decodeInlineExecCwd(call: PublicCliCall): string =
  ## Optional ``cwd`` arg, present only when ``inlineExecCall`` was
  ## called with a non-empty ``cwd``. Empty string when absent.
  for arg in call.arguments:
    if arg.name == "cwd":
      return arg.encodedValue
  ""

# ---------------------------------------------------------------------------
# Public push helper.
# ---------------------------------------------------------------------------

proc toProfileBuildAction*(action: BuildActionDef): ProfileBuildAction =
  ## Convert a ``BuildActionDef`` (the value returned by a typed-tool
  ## ``build`` call or a hand-crafted ``buildAction(... call =
  ## inlineExecCall(...))``) into the flattened
  ## ``ProfileBuildAction`` mirror the apply driver consumes.
  ##
  ## Validates the call shape — only the inline-exec builtin is
  ## accepted inside a profile's ``resources:`` block. Every typed-tool
  ## that emits a profile-scope action edge (Phase F's ``expandArchive``
  ## and any future siblings) lowers via ``inlineExecCall`` so this
  ## restriction matches the spec's surface.
  result = ProfileBuildAction(
    id: action.id,
    argv: decodeInlineExecArgv(action.call),
    cwd: decodeInlineExecCwd(action.call),
    deps: action.deps,
    inputs: action.inputs,
    outputs: action.outputs,
    commandStatsId: action.commandStatsId,
    toolIdentityRefs: action.toolIdentityRefs,
    requiresElevation: action.requiresElevation,
    cacheable: action.cacheable)

proc addProfileBuildAction*(target: var seq[ProfileBuildAction];
                            action: BuildActionDef) =
  ## Push the flattened mirror of ``action`` onto ``target``. The
  ## profile DSL macro wraps every recognized action-edge call site
  ## with this helper so the call's runtime result lands in the
  ## profile's ``buildActions`` seq alongside the live-state
  ## ``ResourceIntent`` items the resource templates emit. The split
  ## by ``ProfileIntent.resources`` vs ``ProfileIntent.buildActions``
  ## is what lets the apply driver route each kind through its own
  ## engine (the elevation broker dispatcher for resources, ``runBuild``
  ## for action edges).
  target.add(toProfileBuildAction(action))

# ---------------------------------------------------------------------------
# Bare ``inlineExecCall(...)`` profile-scope wrapper.
# ---------------------------------------------------------------------------

proc profileInlineExecActionEdge*(
    target: var seq[ProfileBuildAction];
    argv: openArray[string];
    address = "";
    cwd = "";
    inputs: openArray[string] = [];
    outputs: openArray[string] = [];
    dependsOn: openArray[string] = [];
    toolIdentityRefs: openArray[string] = [];
    requiresElevation = false;
    cacheable = true;
    commandStatsId = "") =
  ## Profile-scope shim for ``inlineExecCall(...)`` used inside a
  ## profile's ``resources:`` block. Assembles a ``BuildActionDef``
  ## around the inline-exec call and pushes its flattened mirror onto
  ## ``target``.
  ##
  ## The parameter shape mirrors the spec § 2.3 example:
  ##
  ## ```nim
  ## inlineExecCall(
  ##   argv = @["C:\\actions-runner\\config.cmd", "--unattended", ...],
  ##   toolIdentityRefs = @["C:\\actions-runner\\config.cmd"],
  ##   outputs = @["C:\\actions-runner\\.runner"],
  ##   requiresElevation = true,
  ##   dependsOn = "expandArchiveOutput")
  ## ```
  ##
  ## The ``address`` argument (default ``""``) becomes the
  ## ``BuildActionDef.id`` — when empty we derive a stable identity
  ## from the argv's executable basename so two ``inlineExecCall``
  ## edges that share the same executable + outputs collapse to one
  ## graph node. The derivation here is the simplest stable choice
  ## (``"inlineExec:<argv[0]>"``); profile authors that need finer-
  ## grained dedupe pass an explicit ``address``.
  ##
  ## ``commandStatsId`` defaults to ``"inlineExecCall"`` so the cache
  ## stats classifier separates inline-exec edges from typed-tool
  ## edges; profile authors that want per-edge stats pass an explicit
  ## value.
  ##
  ## The full ``BuildActionDef`` flows through ``buildAction(...)`` so
  ## the global ``buildActionRegistry`` sees the same value an
  ## explicit ``expandArchive.build(...)`` produces — keeps every
  ## downstream registry walker uniform.
  if argv.len == 0:
    raise newException(ValueError,
      "profileInlineExecActionEdge: argv must be non-empty " &
      "(spec § 2.1: an inline-exec edge with empty argv is a " &
      "programming error)")
  let id =
    if address.len > 0: address
    else: "inlineExec:" & argv[0]
  let statsId =
    if commandStatsId.len > 0: commandStatsId
    else: "inlineExecCall"
  let call = inlineExecCall(argv, cwd = cwd)
  let action = buildAction(
    id = id,
    call = call,
    deps = dependsOn,
    inputs = inputs,
    outputs = outputs,
    cacheable = cacheable,
    commandStatsId = statsId,
    toolIdentityRefs = toolIdentityRefs,
    requiresElevation = requiresElevation)
  target.add(toProfileBuildAction(action))
