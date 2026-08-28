## NLF-PROP-1 — a designation reaches the whole closure, and the library's
## recipe never mentions a lock file.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-PROP-1**: "A library used by a
## `hostTools` artifact is built under `hostTools`, its recipe unchanged."
##
## Design §4.1 states the property and why it is not optional:
##
## > **Designation propagates down the dependency closure.** An edge is built
## > under the lock file of the consumer that pulled it in, unless it pins one
## > of its own (§4.6).
##
## > If `codegen` is built under `hostTools` and `uses: libfoo`, then a
## > target-architecture `libfoo` cannot be linked into a host-architecture
## > tool. The link either fails or, worse, succeeds and produces something
## > that cannot run. A designation that did *not* propagate would be a
## > designation that does not work.
##
## ## What makes this more than a table lookup
##
## Two things, and without them the case would pass against an implementation
## that recorded the designation and did nothing with it.
##
## First, the closure is TRANSITIVE. `libfoo` is a direct dependency of the
## designated tool; `libcore` is only reachable through `libfoo`. A one-hop
## implementation records the right thing about `libfoo` and the wrong thing
## about `libcore`, which is precisely the shape §4.1's argument rules out —
## the link failure happens at whatever depth the wrong architecture appears.
##
## Second, the assertion is on the SOLVED GRAPHS, not on the propagation
## table: the packages designated to `hostTools` are the ones that appear in
## `hostTools`'s lock, and they are absent from the other lock. §3 defines a
## lock file as "one complete pinned solved graph", so that is where a
## designation has to be visible to have taken effect.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m7_fixture`'s header, which states the policy in full.

import std/[tables, unittest]

import ./nlf_m7_fixture

const
  Tablegen = "tablegen"
  App = "app"
  LibFoo = "libfoo"
  LibCore = "libcore"

proc workspace(): Recipe =
  ## The §4.3 canonical shape: one package's worth of host tooling and one
  ## shipped binary. `libfoo` and `libcore` designate NOTHING — that is the
  ## property under test, and it is the reason §4.1 calls propagation "the
  ## property that makes the feature adoptable: the library author does
  ## nothing."
  Recipe(
    packages: @[
      RecipePackage(name: Tablegen, versions: @["1.0.0"],
        deps: @[dep(LibFoo, ">=1.0 <2.0")]),
      RecipePackage(name: App, versions: @["1.0.0"],
        deps: @[dep(LibCore, ">=1.0 <2.0")]),
      RecipePackage(name: LibFoo, versions: @["1.4.0"],
        deps: @[dep(LibCore, ">=1.0 <2.0")]),
      RecipePackage(name: LibCore, versions: @["1.1.0"])],
    artifacts: @[
      RecipeArtifact(name: Tablegen, package: Tablegen,
        lockFile: HostToolsLockFileName),
      RecipeArtifact(name: App, package: App, lockFile: "")])

suite "NLF-PROP-1 designation propagates down the closure":

  test "the direct dependency lands under the designated lock file":
    let prop = propagationOf(workspace())
    check prop.lockFilesByPackage[LibFoo] == @[HostToolsLockFileName]

  test "and so does a dependency reached only transitively":
    # `libcore` is two hops from the designated artifact via `tablegen`, and
    # one hop from the undesignated one via `app`. It is therefore built
    # TWICE, once under each — which is the same fact §4.3 states about
    # `libfoo` in its worked example, seen from the transitive end.
    let prop = propagationOf(workspace())
    check prop.lockFilesByPackage[LibCore] ==
      @[DefaultLockFileName, HostToolsLockFileName]
    check prop.instanceCount(LibCore) == 2

  test "the designated closure is what the hostTools lock actually contains":
    let reg = startRegistry("prop1")
    try:
      let solved = reg.solvePerLockFile(workspace())
      check solved.lockFileNames() ==
        @[DefaultLockFileName, HostToolsLockFileName]

      let host = solved[HostToolsLockFileName].solvedVersions()
      check host.hasKey(Tablegen)
      check host.hasKey(LibFoo)
      check host.hasKey(LibCore)

      # And the shipped graph does NOT contain the host tool or the library
      # only it reaches. A designation that propagated everywhere would be
      # indistinguishable from no designation at all.
      let target = solved[DefaultLockFileName].solvedVersions()
      check not target.hasKey(Tablegen)
      check not target.hasKey(LibFoo)
      check target.hasKey(App)
      check target.hasKey(LibCore)
    finally:
      reg.shutdown()

  test "the library's own recipe mentions no lock file":
    # The adoptability claim, asserted rather than described. If this stops
    # being true the feature has acquired a per-library authoring cost, which
    # §1.1's curve is the reason it must not.
    for p in workspace().packages:
      if p.name in [LibFoo, LibCore]:
        check p.pinnedLockFile == ""
    for a in workspace().artifacts:
      if a.package in [LibFoo, LibCore]:
        check a.lockFile == ""
