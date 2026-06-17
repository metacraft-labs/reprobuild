## DSL-port M7 acceptance — helper proc reads the active build context.
##
## Pins the contract for M7's user-facing helper API. The M4 emitter
## wraps every ``build:`` body in a ``beginBuildContext / try / finally
## endBuildContext`` pair (see ``emitM4BuildActions`` and
## ``emitM4ArtifactBuildLowering`` in ``macros_b.nim``). M7 makes the
## active context discoverable from arbitrary Nim procs the recipe author
## defines at module scope and CALLS as side effects from inside the
## build body — the helper executes while the stack frame is still on
## top of ``dslPortActiveBuildContext``.
##
## This file pins the package-level case (``build:`` directly under
## ``package``): a helper called from inside the body sees the package
## name and an empty artifact name. The artifact-scoped case lives in
## ``t_dsl_helper_proc_within_artifact.nim``.
##
## Capture pattern: ``inspectContext`` writes the M7 accessors' return
## values into module-level vars at the time of the call. The ``package``
## macro lowers the ``build:`` body at module-init time inside the
## ``beginBuildContext`` push/pop pair, so by the time the unit tests
## run, ``capturedFromBuild*`` already holds whatever ``inspectContext``
## observed AT THE PUSH SITE. The tests then assert on those captures.
## This verifies the helper actually EXECUTED (not just compiled away)
## inside the active frame.
##
## NOTE: the ``package`` macro emits ``export`` statements and other top-
## level-only Nim, so ``package <name>:`` must sit at module top level —
## not inside a ``test`` body. The captured-vars pattern is how the M4
## acceptance fixtures (``t_dsl_build_with_executable.nim`` etc.) already
## work; M7 follows the same shape.

import std/[unittest]

import repro_project_dsl

# Module-level state the helper writes into when it's reached from inside
# a ``build:`` body. ``ctxPkg``'s build body calls ``inspectContext`` at
# module-init time; the unit tests below read these captures.
var capturedFromBuildPkg: string = "PRE-INIT"
var capturedFromBuildArtifact: string = "PRE-INIT"

# Separate captures for the "called outside a build context" case so the
# build-context test isn't sensitive to call ordering with the empty-
# context probe.
var capturedOutsidePkg: string = "PRE-INIT"
var capturedOutsideArtifact: string = "PRE-INIT"

proc inspectContext() =
  # The point of the helper: invoke the M7 user-facing accessors and
  # publish the values to module-level state. Both accessors are pure
  # reads of the M4 thread-local stack — no allocation, no raise.
  capturedFromBuildPkg = currentBuildPackage()
  capturedFromBuildArtifact = currentBuildArtifact()

proc inspectContextOutside() =
  # Same accessors, different capture vars. Called at module top level
  # BEFORE the ``package`` declaration so the build-context stack is
  # provably empty at the call site.
  capturedOutsidePkg = currentBuildPackage()
  capturedOutsideArtifact = currentBuildArtifact()

# Probe the empty-stack case FIRST so the assertion is robust even if
# the M4 emission below leaves residual state. The empty-stack contract
# is that ``currentBuildPackage`` / ``currentBuildArtifact`` both return
# ``""`` when no ``build:`` block is open.
inspectContextOutside()

# Package-level ``build:`` block whose body invokes the helper. The M4
# emitter pushes ``("ctxPkg", "")`` onto the stack, runs the body
# verbatim (so ``inspectContext`` executes inside the frame), and pops
# in the ``finally`` clause. Top-level placement is required because
# ``package`` emits ``export``-bearing code.
package ctxPkg:
  build:
    inspectContext()

suite "DSL-port M7 — helper proc reads build context":
  test "helper proc called from package-level build: sees package":
    # The helper ran inside the M4-emitted ``beginBuildContext("ctxPkg",
    # "") / try / finally endBuildContext()`` pair, so it observed the
    # package frame at module-init time.
    check capturedFromBuildPkg == "ctxPkg"
    # Package-level ``build:`` records with an empty ``artifactName``
    # (the M4 discriminator between package-level and artifact-scoped
    # forms). The helper sees the same empty string.
    check capturedFromBuildArtifact == ""

  test "helper called outside build: sees empty context":
    # ``inspectContextOutside`` ran at module top level BEFORE any
    # ``package`` was opened, so the stack was empty. The M7 accessors
    # surface ``""`` for both fields on an empty stack. The capture vars
    # were initialised to ``"PRE-INIT"`` so this also proves the helper
    # was actually reached (it overwrote the sentinel).
    check capturedOutsidePkg == ""
    check capturedOutsideArtifact == ""
    check capturedOutsidePkg != "PRE-INIT"
    check capturedOutsideArtifact != "PRE-INIT"
