## DSL-port M9.F acceptance — typed ``DslOutputRef`` handles.
##
## Pins the contract for M9.F's extension of M4's ``output(path)``:
##
##   * ``output(path)`` now ALSO returns a ``DslOutputRef`` whose three
##     fields (packageName / artifactName / path) reflect the live build-
##     context frame plus the recorded path. The proc is annotated
##     ``{.discardable.}`` so legacy bare-statement callers (``output("…")``
##     ignoring the return value) still compile without warnings.
##   * The M4 ``registeredOutputs`` string registry stays byte-identical;
##     M9.F adds a PARALLEL ``registeredOutputRefs`` typed registry so
##     callers can recover the producer-identity metadata along with the
##     path.
##   * The function-form shorthand ``outputOf(packageName, artifactName)``
##     stands in for v8's ``<ident>.output`` dot syntax — M3's ident
##     injection is unchanged, so the cleaner dot-syntax is DEFERRED.
##     ``outputOf`` echoes the producer's first registered output, or a
##     placeholder handle with ``path == ""`` when nothing is registered
##     against the named producer yet.
##
## Why two tests: Test 1 exercises the inside-a-``build:``-block path
## (output() returns a non-empty handle that reflects the active frame).
## Test 2 exercises the outside-a-``build:``-block path (outputOf() looks
## up the producer in the typed-output registry). The two paths are
## disjoint and both need to be pinned because NDE0-K's kernel rewrite
## leans on outputOf() as the consumer-side surface while leaving the
## producer-side bare ``output("…")`` statement form unchanged.

import std/[unittest]

import repro_project_dsl

# Producer fixture — declares one output inside a ``files`` artifact's
# ``build:`` block and stores the typed handle via the M9.F return value.
# A module-scope ``var`` captures the handle so the test cases can
# inspect it after the package macro has finished expanding.
var outputRefFromBuild: DslOutputRef

package fooPkg:
  files configFile:
    build:
      outputRefFromBuild = output("/build/config-used")

suite "DSL-port M9.F — output() returns a DslOutputRef":

  test "M4 string registry still records exactly one entry":
    # M9.F EXTENDS M4 without disturbing the legacy registry shape.
    # The ``registeredOutputs`` accessor must observe the same single
    # entry it would have seen before the M9.F extension landed.
    let outputs = registeredOutputs("fooPkg", "configFile")
    check outputs.len == 1
    check outputs[0] == "/build/config-used"

  test "M4 build-action registry still records the artifact-scoped action":
    # M9.F MUST NOT regress the M4 build-action registry. The legacy
    # ``registeredBuildActions`` accessor still observes the single
    # ``configFile`` artifact-scoped entry.
    let actions = registeredBuildActions("fooPkg")
    check actions.len == 1
    check actions[0].artifactName == "configFile"

  test "output() returns a handle whose three fields match the live frame":
    # The returned handle reflects the producer's package + artifact
    # name (the active build-context frame at the call site) and the
    # path string the caller passed. ``configFile`` is inside ``fooPkg``
    # so packageName == "fooPkg" and artifactName == "configFile".
    check outputRefFromBuild.packageName == "fooPkg"
    check outputRefFromBuild.artifactName == "configFile"
    check outputRefFromBuild.path == "/build/config-used"

  test "registeredOutputRefs echoes the typed handle":
    # The typed registry MUST contain the same handle (path + producer
    # identity) the proc returned, in registration order.
    let refs = registeredOutputRefs("fooPkg", "configFile")
    check refs.len == 1
    check refs[0].packageName == "fooPkg"
    check refs[0].artifactName == "configFile"
    check refs[0].path == "/build/config-used"

suite "DSL-port M9.F — outputOf() function-form shorthand":

  test "outputOf() recovers the producer's first registered output":
    # NDE0-K consumer-side surface: pass an outputOf() lookup as a
    # tool input. The handle must round-trip through the typed registry
    # without losing the producer-identity metadata.
    let h = outputOf("fooPkg", "configFile")
    check h.packageName == "fooPkg"
    check h.artifactName == "configFile"
    check h.path == "/build/config-used"

  test "outputOf() on an unknown producer returns a placeholder handle":
    # When the producer has not registered any output yet (or the name
    # is mis-spelled), ``outputOf`` echoes the package/artifact name the
    # caller asked about with an empty path. This keeps the consumer-
    # side call expression total — registerBuildInput sees the empty
    # path and surfaces the gap rather than raising at macro-expansion
    # time. The wiring fixture (``t_dsl_build_input_wiring``) shows the
    # happy path where the producer DOES exist; here we pin the
    # placeholder shape.
    let h = outputOf("fooPkg", "noSuchArtifact")
    check h.packageName == "fooPkg"
    check h.artifactName == "noSuchArtifact"
    check h.path == ""
