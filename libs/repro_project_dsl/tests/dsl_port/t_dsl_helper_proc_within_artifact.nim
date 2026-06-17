## DSL-port M7 acceptance — helper proc reads artifact-scoped build
## context + post-block stack unwind.
##
## Companion to ``t_dsl_helper_proc_reads_build_context.nim`` which pins
## the package-level case. This file pins:
##
##   1. The artifact-scoped case: a helper called from inside an
##      ``executable myTool: build: ...`` body sees both the package name
##      AND the artifact name. The M4 emitter pushes
##      ``beginBuildContext("artCtxPkg", "myTool")``; the helper observes
##      both fields populated.
##
##   2. The stack unwinds after the artifact ``build:`` exits. The M4
##      emitter pairs ``beginBuildContext`` with ``endBuildContext`` in a
##      ``finally`` clause, so once the artifact body's try-block exits
##      the frame is popped. A helper invoked AFTER all the M4-emitted
##      try/finally blocks have run must NOT still observe the artifact's
##      frame on the stack.
##
## The second case is a regression guard for the "context leak" failure
## mode an earlier emitter-side implementation could hit (e.g. forgetting
## the ``finally``, or using a module-level scalar rather than a stack).
## The assertion is deliberately scoped to "the value is NOT the
## artifact's frame" rather than fixing a specific post-pop value,
## because the post-pop observation depends on whether the helper sits
## inside a still-open OUTER package frame or fully outside any frame.
## Both are correct outcomes for this milestone.
##
## NOTE: as with the package-level fixture, ``package`` must sit at
## module top level (it emits ``export``-bearing code). Module-level
## capture vars hold the values the helper recorded at module-init time.

import std/[unittest]

import repro_project_dsl

# Capture from inside the artifact ``build:`` body (test case 1).
var capturedArtPkg: string = "PRE-INIT"
var capturedArtArtifact: string = "PRE-INIT"

# Capture from a probe placed AFTER the artifact's build: ran (test case
# 2). The seed is a sentinel distinct from any expected post-unwind
# value so a missing-unwind regression is observable as the sentinel
# surviving.
var capturedAfterPkg: string = "STALE"
var capturedAfterArtifact: string = "STALE"

proc inspectContextArt() =
  capturedArtPkg = currentBuildPackage()
  capturedArtArtifact = currentBuildArtifact()

proc inspectContextAfter() =
  capturedAfterPkg = currentBuildPackage()
  capturedAfterArtifact = currentBuildArtifact()

# Case 1: artifact-scoped build: body invokes the helper. M4 pushes
# ``("artCtxPkg", "myTool")`` before splicing the body, pops in finally.
package artCtxPkg:
  executable myTool:
    build:
      inspectContextArt()

# Case 2: separate package whose artifact's build: body is a no-op. After
# the package macro's emitted M4 push/pop pair for ``("artCtxPkg2",
# "myTool2")`` has run and unwound, we probe the stack. ``package``
# expansion + ``inspectContextAfter()`` are independent top-level
# statements; the probe runs at module-init time AFTER the M4 blocks
# the macro emitted for ``artCtxPkg2`` have already pushed AND popped.
package artCtxPkg2:
  executable myTool2:
    build:
      discard
inspectContextAfter()

suite "DSL-port M7 — helper proc reads artifact context":
  test "helper called from artifact build: sees artifact + package":
    # Both fields populated because the M4 emitter pushed both the
    # package name AND the artifact name onto the active context.
    check capturedArtPkg == "artCtxPkg"
    check capturedArtArtifact == "myTool"

  test "context unwinds after artifact build: exits":
    # ``inspectContextAfter`` overwrote the ``"STALE"`` sentinel, so we
    # know it ran. The exact post-unwind value is not pinned (it depends
    # on whether an outer frame remained open or the stack went fully
    # empty) — the regression guard is "the artifact's frame is gone".
    check capturedAfterPkg != "STALE"
    check capturedAfterArtifact != "STALE"
    # Critical regression guard: the artifact's frame did NOT survive
    # past the artifact body's finally-block.
    check capturedAfterArtifact != "myTool2"
