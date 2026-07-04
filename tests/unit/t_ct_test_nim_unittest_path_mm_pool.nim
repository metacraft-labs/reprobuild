## RX-rollout hardening: ``ct_test_nim_unittest`` threads a project's
## ``--path:`` / ``--mm:`` compile flags and an engine build-pool through
## its typed test-tool wrapper.
##
## Falsifiable emission test for the passthroughs added on top of the
## M4 ``buildNimUnittest`` rewrite:
##
##   * ``build(..., paths = @["src", "tests"])`` must emit one
##     ``--path:src`` and one ``--path:tests`` argv token (the ``nim``
##     profile's repeated concat-form ``--path:`` flag — see
##     ``libs/repro_dsl_stdlib/.../packages/nim.nim`` subcmd ``c``).
##   * ``build(..., mm = "orc")`` must emit a single ``--mm:orc`` token
##     (the ``nim`` profile's single-valued concat-form ``--mm:`` flag).
##   * ``run(..., pool = "p", poolUnits = 1)`` must stamp the resulting
##     ``BuildActionDef.pool`` = ``"p"`` (the engine's
##     ``BuildAction.pool`` / ``poolRunning`` capacity surface, reached
##     via ``recordToolInvocation`` → ``recordCommandAction`` →
##     ``buildAction``).
##
## Defaults (``paths = @[]``, ``mm = ""``, ``pool = ""``,
## ``poolUnits = 1``) must preserve the pre-passthrough behaviour: no new
## flag token and no pool assignment. That guards every existing call
## site — the ``repro_tests.nim`` test-spec loop and the spec fixtures
## keep their byte-identical argv.
##
## The argv reconstruction below mirrors ``argvForCall``'s emission rules
## (``libs/repro_cli_support/src/repro_cli_support.nim``): a ``cafConcat``
## flag renders as ``alias & value`` per value, and a ``seq[string]``
## flag's ``encodedValue`` is ``\x1f``-joined (``cliArgSeq``). Asserting
## on the reconstructed token list — rather than on raw struct fields —
## keeps the check tied to what the engine actually feeds ``nim c``.

import std/[sequtils, strutils, unittest]

import ct_test_nim_unittest

proc emittedFlagTokens(action: BuildActionDef): seq[string] =
  ## Reconstruct the flag argv tokens the engine would emit for this
  ## action's recorded ``PublicCliCall``, following ``argvForCall``'s
  ## ``cafConcat`` rule (``alias & value``, one token per seq element).
  ## Positional args (the ``source``) are intentionally excluded — only
  ## flag tokens are relevant to the ``--path:`` / ``--mm:`` assertions.
  for arg in action.call.arguments:
    if arg.kind == cpkPositional:
      continue
    var values: seq[string] = @[]
    if arg.nimType.normalize == "seq[string]":
      if arg.encodedValue.len > 0:
        for item in arg.encodedValue.split("\x1f"):
          values.add(item)
    elif arg.nimType.normalize == "bool":
      if arg.encodedValue.normalize == "true":
        result.add(arg.alias)
      continue
    else:
      values.add(arg.encodedValue)
    let flagName = if arg.alias.len > 0: arg.alias else: "--" & arg.name
    for value in values:
      case arg.format
      of cafSeparate:
        result.add(flagName)
        result.add(value)
      of cafConcat:
        result.add(flagName & value)
      of cafEquals:
        result.add(flagName & "=" & value)

suite "ct_test_nim_unittest RX passthroughs — --path: / --mm: / build-pool":

  # Each ``build``/``run`` call below uses a DISTINCT binary path so the
  # global implicit-target-name registry (keyed on the output basename)
  # does not reject the reused name across independent test cases. The
  # ``run`` cases additionally pass ``registerImplicitName = false`` — the
  # execute edge's implicit name would otherwise collide with its own
  # build edge's, exactly as the B3 two-edge shape documents.

  test "build emits one --path: token per paths entry (repeated concat)":
    let edge = buildNimUnittest.build(
      source = "tests/foo.nim",
      binary = "build/test-bin/rx_paths",
      paths = @["src", "tests"])
    let tokens = emittedFlagTokens(edge.action)
    check "--path:src" in tokens
    check "--path:tests" in tokens
    # exactly one token per entry — no duplication, no collapse.
    check tokens.count("--path:src") == 1
    check tokens.count("--path:tests") == 1

  test "build emits a single --mm: token for mm":
    let edge = buildNimUnittest.build(
      source = "tests/foo.nim",
      binary = "build/test-bin/rx_mm",
      mm = "orc")
    let tokens = emittedFlagTokens(edge.action)
    check "--mm:orc" in tokens
    check tokens.count("--mm:orc") == 1

  test "build with default paths/mm emits no --path:/--mm: token":
    let edge = buildNimUnittest.build(
      source = "tests/foo.nim",
      binary = "build/test-bin/rx_defaults")
    let tokens = emittedFlagTokens(edge.action)
    for token in tokens:
      check not token.startsWith("--path:")
      check not token.startsWith("--mm:")

  test "run(pool=, poolUnits=) stamps BuildAction.pool":
    let handle = NimUnittestBinary(path: "build/test-bin/rx_run_pool")
    let action = handle.run(pool = "serial-pty", poolUnits = 1'u32,
      registerImplicitName = false)
    check action.pool == "serial-pty"
    check action.poolUnits == 1'u32

  test "run with default pool leaves BuildAction.pool empty":
    let handle = NimUnittestBinary(path: "build/test-bin/rx_run_default")
    let action = handle.run(registerImplicitName = false)
    check action.pool == ""
    check action.poolUnits == 1'u32
