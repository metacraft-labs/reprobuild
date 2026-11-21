## DSL-port M9.R.14c.4 — inline-exec actions inherit PATH from
## resolved tool profiles + per-edge extraEnv.
##
## ## Context
##
## Smoke iteration 2 of the M9.R.14c expat campaign tripped on
## autoconf's configure script:
##
##   configure: error: no acceptable m4 could be found in $PATH
##
## Root cause: ``autotools_package`` emits its configure action via
## ``inlineExecCall(["sh", "-c", "./configure ..."])``. Inside
## ``lowerGraphAction`` (in ``repro_cli_support``) the
## ``reprobuild.builtin.exec`` branch was missing the
## ``actionPathPrefix`` injection that the typed-tool branch (below it)
## already had. So the inline-exec action's spawned ``sh`` saw only
## ``getEnv("PATH")`` — which inside a from-source nix-shell does NOT
## include the resolved tool profiles' bin dirs (m4, perl, make, ...
## are all stdlib-provisioned for autoconf but never reached the
## action's PATH).
##
## The fix lifts the same enrichment used by the typed-tool branch
## into the inline-exec branch: prepend ``actionPathPrefix`` (the
## union of all resolved tool profile bin dirs in the build identity)
## to PATH, then append the per-edge ``payload.env`` overrides.
##
## ## What this test pins
##
## The constructor emits an inline configure action and intrinsically declares
## sh, awk, and diff, including provisioning on direct imports. The real
## subprocess regression lives in integration/t_autotools_configure_tools.nim.

import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/constructors/autotools_package

# Exercise the constructor's own imports, rather than the broad constructors
# aggregator: recipes may import this constructor directly.
import repro_dsl_stdlib/nixpkgs_pin

suite "DSL-port M9.R.14c.4 — autotools configure inline-exec shape":

  test "configure action call is reprobuild.builtin.exec":
    # The inline-exec path is what triggers the engine's PATH
    # enrichment branch we fixed in lowerGraphAction. Pin the
    # constructor's choice of call shape so a future refactor
    # doesn't silently switch it to a typed-tool call (which would
    # take the OTHER lowering branch and unrelated PATH behaviour).
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("inlineExecShapePkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      check pkg.buildEdge.call.packageName == "reprobuild.builtin"
      check pkg.buildEdge.call.executableName == "exec"
    finally:
      clearCurrentOwningPackageOverride()

  test "configure intrinsically provisions the Autoconf substitution tools":
    let action = autotools_package(srcDir = "src").buildEdge
    for name in ["sh", "awk", "diff"]:
      check name in action.toolIdentityRefs
      var found = false
      for pkg in registeredPackages():
        if pkg.packageName == name:
          found = true
          require pkg.nixProvisioning.len > 0
          check pkg.nixProvisioning[0].nixpkgsRev == CanonicalNixpkgsRev
          check pkg.nixProvisioning[0].nixpkgsNarHash == CanonicalNixpkgsNarHash
          check pkg.nixProvisioning[0].executablePath == "bin/" & name
      check found

  test "configure action declares sh in toolIdentityRefs":
    # ``sh`` rides on the configure action's tool-identity refs so the
    # engine's resolver prepends the sh bin dir to PATH. Combined with
    # the new ``actionPathPrefix`` injection (which adds EVERY
    # resolved tool profile's bin dir), the configure script can shell
    # out to m4 / perl / make / etc. found through nativeBuildDeps.
    resetDslPortFetchState()
    setCurrentOwningPackageOverride("shRefPkg")
    try:
      let pkg = autotools_package(srcDir = "./src")
      var hasSh = false
      for refName in pkg.buildEdge.toolIdentityRefs:
        if refName == "sh":
          hasSh = true
          break
      check hasSh
    finally:
      clearCurrentOwningPackageOverride()
