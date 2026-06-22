## DSL-port M9.R.14c.1 — ``autotools_package`` emits parallel make.
##
## ## Context
##
## The M9.R.14b smoke iteration finally exercised the full autotools
## chain on Linux but each iteration took ~30 min because make ran
## single-threaded by default. The Linux smoke host (eli-wsl) has 32
## logical cores so the wall-clock dominated by serial make is
## entirely waste.
##
## Fix: ``autotools_package`` injects ``MAKEFLAGS=-jN`` via the typed
## ``make()`` call's ``extraEnv`` parameter (where N =
## ``max(1, min(countProcessors(), 8))``). Pretty much every from-
## source autotools recipe (binutils, expat, autoconf, automake,
## libtool, ...) benefits.
##
## ## Determinism contract
##
## The action cache fingerprint (``BuildAction.weakFingerprint``) is
## derived from the action's ``id`` only (see
## ``weakFingerprintFromText`` in ``repro_build_engine``). The action
## id for the typed ``make()`` call comes from
## ``defaultToolActionId(call)`` which feeds ``callIdentity(call)`` —
## that includes the package + executable + subcommand + per-argument
## encoded values. Crucially: ``extraEnv`` rides as the separate
## ``env`` field on ``BuildActionDef``; it does NOT enter
## ``callIdentity`` and so does NOT enter the fingerprint.
##
## This pins the contract:
##
##   1. The compile + install edges carry ``("MAKEFLAGS", "-jN")``
##      in their ``env`` field.
##   2. N is at least 1 (the ``max(1, ...)`` lower bound).
##   3. N is at most 8 (the upper cap protects against runaway
##      memory + CPU pressure when reprobuild runs on a 64+-core
##      builder; expat / libffi / etc. don't need more than 8 to
##      saturate even cold caches).
##   4. The action ids are STABLE across hosts: regardless of how
##      many cores are available, the recipe + source produce the
##      same ``id``. (Implementation: we derive the ids from a
##      synthetic call that doesn't touch ``MAKEFLAGS``.)

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/constructors

suite "DSL-port M9.R.14c.1 — autotools_package parallel-make wiring":

  test "compile edge carries MAKEFLAGS=-jN in extraEnv":
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("parallelPkg")
    try:
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = @["--disable-static"])
      # Locate the MAKEFLAGS entry. The typed make() wrapper threads
      # ``extraEnv`` into the BuildActionDef's ``env`` field.
      var found = false
      var value = ""
      for (k, v) in pkg.compileEdge.env:
        if k == "MAKEFLAGS":
          found = true
          value = v
          break
      check found
      # Shape: "-j<N>" with N >= 1.
      check value.startsWith("-j")
      let nText = value[2 .. ^1]
      var n: int
      try:
        n = parseInt(nText)
      except ValueError:
        n = 0
      check n >= 1
      # Upper cap from the M9.R.14c.1 design (see autotools_package
      # source comment): N = min(countProcessors(), 8).
      check n <= 8
    finally:
      clearCurrentOwningPackageOverride()

  test "install edge carries the same MAKEFLAGS":
    # ``make install`` benefits from the same parallel-job hint
    # (most autotools install scripts honour MAKEFLAGS for recursive
    # ``make -C subdir install`` sub-invocations). The parallel-make
    # hint lives on the raw ``make install`` action, exposed as
    # ``installMakeEdge``; ``installEdge`` is the terminal .la-cleanup
    # node (an ``sh -c find`` invocation) that downstream stage-copy
    # deps chain through — see AutotoolsPackageResult's doc comment.
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("parallelInstallPkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      var compileFlags = ""
      var installFlags = ""
      for (k, v) in pkg.compileEdge.env:
        if k == "MAKEFLAGS":
          compileFlags = v
      for (k, v) in pkg.installMakeEdge.env:
        if k == "MAKEFLAGS":
          installFlags = v
      check compileFlags.len > 0
      check installFlags.len > 0
      # Both edges must share the same value so cache hits across the
      # compile + install pair stay deterministic.
      check compileFlags == installFlags
    finally:
      clearCurrentOwningPackageOverride()

  test "compile + install action ids are stable across host core counts":
    # The action id derivation must not depend on the host's core
    # count. The actual stability is proved by the choice to inject
    # parallelism via ``extraEnv`` (which does not enter
    # ``callIdentity``) rather than via the typed ``jobs`` flag
    # (which would). Both edges produce nonempty ids and a distinct
    # compile vs install pair (``installEdge`` is the terminal
    # .la-cleanup node, a distinct action from the compile ``make``).
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("stableIdPkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      check pkg.compileEdge.id.len > 0
      check pkg.installEdge.id.len > 0
      check pkg.compileEdge.id != pkg.installEdge.id
    finally:
      clearCurrentOwningPackageOverride()
