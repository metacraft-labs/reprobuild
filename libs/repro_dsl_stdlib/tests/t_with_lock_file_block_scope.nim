## `withLockFile <name>:` affects exactly the edges emitted inside it.
##
## Named-Lock-Files NLF-M7. Design §4.4 and its §17 validation criterion: "The
## block affects exactly the edges emitted within it; typed-tool wrappers pick
## it up through `currentBuildContext()` with no new parameters."
##
## ## Corpus case **NLF-PROP-6** — a `withLockFile` region governs its body,
## ## and only its body
##
## NLF-M7 shipped this file with no corpus id, and recorded the gap here
## rather than papering over it: the campaign's convention is that a test
## without an id is not ready to be worked. The id was added to
## `Named-Lock-Files-Test-Corpus.md` on 2026-08-21 and this file now carries
## it. The case, in full:
##
## > **Input.** One `build:` block containing two sequential `withLockFile`
## > regions naming different lock files, with an edge declared before the
## > first region, one inside each region, and one after the second.
## > **Expect.** The two enclosed edges are governed by their respective
## > regions; the edge before and the edge after are governed by the
## > package-level default. A designation set inside a region does not survive
## > past its `finally`.
##
## It names two defects: "the push/pop being a set rather than a stack (the
## second region would leak into the trailing edge), and a lazily-filled slot
## filled once per *frame* rather than once per *region* — which serves the
## second region the first region's answer. That second defect was found
## during NLF-M7 by a test written for something else, which is why this case
## exists: §4.4 requires a designation to 'differ between two regions of one
## build body', and nothing in groups §3–§8 exercises two regions in
## sequence."
##
## The "two regions in sequence" shape is the last test in this file. Every
## other test here predates the id and covers ONE region; they are kept
## because each isolates a different clause, and the sequential case is added
## rather than substituted because it is the only one that can observe the
## second defect at all.
##
## ## The three properties, and why each is separately falsifiable
##
##   * **Exactly the edges within it.** A block that leaked would designate
##     the rest of the build body; a block that under-reached would designate
##     nothing. Both are checked, before AND after the block.
##   * **Through `currentBuildContext()`, with no new parameters.** §4.4's
##     phrasing is deliberate — "every stdlib helper and typed-tool wrapper
##     reads policy from `currentBuildContext()` **today**, so none of them
##     need a new parameter". So the assertion is made through the accessor a
##     wrapper actually calls, not through the designation stack directly.
##   * **`{.dirty.}` with an `untyped` block argument.** §4.4: "block
##     arguments in this DSL are declared `untyped` rather than `string` so
##     the command-call block form parses at all", and `evalConfig` is dirty
##     "so identifiers introduced by inner macros flow back into the
##     surrounding scope without hygienic renaming".
##
## ## [MEASURED] One §4.4 sentence overstates what any of these templates do
##
## §4.4 says `withLockFile` must follow `evalConfig` on both points "or its
## body will not be able to introduce `let` bindings the rest of the `build:`
## block can see — which the examples above rely on". The first clause is not
## achievable and the second is not true of the examples.
##
## `{.dirty.}` controls HYGIENE — whether an identifier is renamed — not
## SCOPE. Both this template and `evalConfig` wrap the body in `try`/`finally`
## (the same shape, for the same reason), and a Nim `try` opens a scope, so a
## `let` introduced in the body is out of scope after the block whether the
## template is dirty or not. `evalConfig` has had exactly this property since
## it landed.
##
## And §4.4's own example does not rely on the claim: its `let tables =
## tablegen.emit(...)` sits AFTER the `withLockFile` block, not inside it. So
## the sentence is loose rather than the implementation being wrong, and the
## properties asserted below are the ones that are both real and needed:
## dirtiness (the body sees the enclosing scope unrenamed, and bindings it
## makes are visible for the REST OF THE BODY), and the `untyped` argument
## (the command-call block form parses at all — asserted by this file
## compiling).
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## A real `beginBuildBlock` frame, the real `withLockFile` template, and the
## real `currentBuildContext()` accessor a typed-tool wrapper reads.

import std/[unittest]

import repro_dsl_stdlib/active_context
import repro_lock_files
import repro_project_dsl

suite "withLockFile scopes exactly its own body":

  setup:
    resetLockFileScopes()
    resetLockFileDeclarations()
    discard declareLockFile("targetRuntime")

  teardown:
    resetLockFileScopes()

  test "inside the block the context reports the block's lock file":
    let state = beginBuildBlock("mytool", "executable", "app")
    try:
      withLockFile "hostTools":
        check currentBuildContext().lockFileName == "hostTools"
    finally:
      endBuildBlock(state)

  test "before and after, it reports what the block did not change":
    let state = beginBuildBlock("mytool", "executable", "app")
    try:
      check currentBuildContext().lockFileName == DefaultLockFileName
      withLockFile "hostTools":
        check currentBuildContext().lockFileName == "hostTools"
      check currentBuildContext().lockFileName == DefaultLockFileName
    finally:
      endBuildBlock(state)

  test "an artifact designation is restored after a block overrides it":
    # §4.3's precedence chain, narrowest winning: the block outranks the
    # artifact for its own extent and not one statement further.
    let state = beginBuildBlock("mytool", "executable", "app")
    try:
      currentBuildContext().setLockFile("targetRuntime")
      check currentBuildContext().lockFileName == "targetRuntime"
      withLockFile "hostTools":
        check currentBuildContext().lockFileName == "hostTools"
      check currentBuildContext().lockFileName == "targetRuntime"
    finally:
      endBuildBlock(state)
      resetLockFileScopes()

  test "blocks nest, and the innermost wins":
    let state = beginBuildBlock("mytool")
    try:
      withLockFile "targetRuntime":
        check currentBuildContext().lockFileName == "targetRuntime"
        withLockFile "hostTools":
          check currentBuildContext().lockFileName == "hostTools"
        check currentBuildContext().lockFileName == "targetRuntime"
    finally:
      endBuildBlock(state)

  test "a raise inside the body does not leave the designation behind":
    # §4.4 puts push/pop in a `try`/`finally` for the reason `evalConfig`
    # does. Without it, one failing edge would silently designate every later
    # edge in the build body — a §4.9-class silent misbuild reached through an
    # error path, which is where nobody looks.
    let state = beginBuildBlock("mytool")
    try:
      var raised = false
      try:
        withLockFile "hostTools":
          raise newException(ValueError, "recipe failed mid-block")
      except ValueError:
        raised = true
      check raised
      check currentBuildContext().lockFileName == DefaultLockFileName
    finally:
      endBuildBlock(state)

  test "the body sees the enclosing scope, unrenamed":
    # The `{.dirty.}` requirement, asserted as a compile. Under a hygienic
    # template the body's reference to `binary` would be renamed and would not
    # resolve to the binding above it, so this test failing to COMPILE is the
    # failure mode rather than a failing check.
    let state = beginBuildBlock("mytool")
    try:
      let binary = "build/tablegen"
      withLockFile "hostTools":
        let tables = binary & ".tables"
        check tables == "build/tablegen.tables"
        check currentBuildContext().lockFileName == "hostTools"
      # §4.4's own example puts the follow-on `let` HERE, outside the block,
      # which is what the `try`-scoped body permits.
      let generated = binary & ".c"
      check generated == "build/tablegen.c"
    finally:
      endBuildBlock(state)

  test "NLF-PROP-6: two SEQUENTIAL regions, and four edges around them":
    # The corpus case as written. Four edge positions — before, inside the
    # first, inside the second, after — because the two defects the case
    # names are each invisible from three of them:
    #
    #   * a push/pop implemented as a SET rather than a stack leaves the
    #     second region's name in place, so only the edge AFTER can see it;
    #   * a slot filled once per FRAME rather than once per region serves the
    #     second region the FIRST region's answer, so only the edge inside
    #     the SECOND region can see it. Nesting cannot: an inner region of a
    #     nested pair is entered while the outer one is still live, so a
    #     once-per-frame slot and a once-per-region slot agree there.
    #
    # Every assertion is made through `currentBuildContext()`, which is what
    # §4.4 says a typed-tool wrapper reads, rather than through the
    # designation stack — an implementation whose stack was right and whose
    # context accessor was memoised would pass the stack assertion.
    let state = beginBuildBlock("mytool", "executable", "app")
    try:
      # The edge before the first region: the package-level default.
      check currentBuildContext().lockFileName == DefaultLockFileName

      withLockFile "hostTools":
        check currentBuildContext().lockFileName == "hostTools"

      # Between the regions, back to the default — not carried by the first.
      check currentBuildContext().lockFileName == DefaultLockFileName

      withLockFile "targetRuntime":
        # The second region gets its OWN answer. A once-per-frame slot
        # answers `hostTools` here.
        check currentBuildContext().lockFileName == "targetRuntime"

      # The edge after the second region: the package-level default again. A
      # set-not-a-stack implementation answers `targetRuntime` here.
      check currentBuildContext().lockFileName == DefaultLockFileName
    finally:
      endBuildBlock(state)

  test "the per-call argument outranks the block for one call":
    # §4.5's escape hatch, and the narrowest rung of §4.3's chain. Empty means
    # "not supplied", so a wrapper can thread it unconditionally.
    let state = beginBuildBlock("mytool")
    try:
      withLockFile "hostTools":
        withLockFileArgument("targetRuntime"):
          check currentBuildContext().lockFileName == "targetRuntime"
        check currentBuildContext().lockFileName == "hostTools"
        withLockFileArgument(""):
          check currentBuildContext().lockFileName == "hostTools"
    finally:
      endBuildBlock(state)
