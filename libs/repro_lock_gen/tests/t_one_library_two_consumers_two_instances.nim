## NLF-PROP-2 — two artifacts under two lock files give two coexisting
## instances of one shared library.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-PROP-2**: "Two artifacts under
## two lock files yield two coexisting instances of a shared library."
##
## Design §4.3's worked example, stated as the outcome:
##
## > `libfoo` in the example above is designated nowhere. It is built
## > **twice** — once under `hostTools` for `tablegen`, once under
## > `targetRuntime` for `app` — and its recipe never mentions lock files.
##
## ## Why the CONTROL is the whole test
##
## "Two instances" is trivially satisfiable by an implementation that just
## runs the solver twice on the same inputs. What makes it meaningful is that
## the two instances DISAGREE, and that the disagreement is one a single lock
## file cannot represent. §13.2 says why in the solver's own terms: the solver
## produces "one concrete package instance per solved package node", so it
## "cannot currently give `libfoo` two instances no matter which list it is
## written in".
##
## So the two consumers below demand DISJOINT version ranges of `libfoo`
## (`>=1.0 <1.5` for the host tool, `>=1.5 <2.0` for the shipped binary). Under
## two lock files both resolve, at different versions. Under one — the control
## in the last test — the union of the two constraints is **unsatisfiable**,
## and that UNSAT is the evidence that this shape has no single-lock-file
## spelling at all.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m7_fixture`'s header, which states the policy in full.

import std/[strutils, tables, unittest]

import repro_lock_gen

import ./nlf_m7_fixture

const
  Tablegen = "tablegen"
  App = "app"
  LibFoo = "libfoo"
  TargetRuntime = "targetRuntime"
  Published = ["1.0.0", "1.2.0", "1.4.0", "1.6.0", "1.9.0"]

proc workspace(): Recipe =
  Recipe(
    packages: @[
      RecipePackage(name: Tablegen, versions: @["1.0.0"],
        deps: @[dep(LibFoo, ">=1.0 <1.5")]),
      RecipePackage(name: App, versions: @["1.0.0"],
        deps: @[dep(LibFoo, ">=1.5 <2.0")]),
      RecipePackage(name: LibFoo, versions: @Published)],
    artifacts: @[
      RecipeArtifact(name: Tablegen, package: Tablegen,
        lockFile: HostToolsLockFileName),
      RecipeArtifact(name: App, package: App, lockFile: TargetRuntime)])

suite "NLF-PROP-2 one library, two consumers, two instances":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime, description = "What we ship.")

  test "the shared library is instantiated under both lock files":
    let prop = propagationOf(workspace())
    check prop.instanceCount(LibFoo) == 2
    check prop.lockFilesByPackage[LibFoo] ==
      @[HostToolsLockFileName, TargetRuntime]

  test "the two instances resolve to DIFFERENT versions":
    let reg = startRegistry("prop2")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      let host = solved[HostToolsLockFileName].solvedVersions()
      let target = solved[TargetRuntime].solvedVersions()

      # Both graphs are complete: each carries its own consumer and its own
      # instance of the shared library.
      check host.hasKey(LibFoo)
      check target.hasKey(LibFoo)

      # And they disagree, which is what makes them two instances rather than
      # one answer read twice.
      check host[LibFoo] == "1.4.0"
      check target[LibFoo] == "1.9.0"
      check host[LibFoo] != target[LibFoo]
    finally:
      reg.shutdown()

  test "the two lock files have DIFFERENT identities":
    # §6.2: identity is derived from the solved graph. Two graphs that pin
    # different versions are two lock files, and §7 then keys their edges
    # apart. If these collided, every edge under one would be free to serve
    # the other's artifacts.
    let reg = startRegistry("prop2-identity")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      check solved[HostToolsLockFileName].lockIdentity.isValid()
      check solved[TargetRuntime].lockIdentity.isValid()
      check solved[HostToolsLockFileName].lockIdentity !=
        solved[TargetRuntime].lockIdentity
    finally:
      reg.shutdown()

  test "there is no single-lock-file spelling of this workspace":
    # The control. With both designations ignored the two disjoint ranges land
    # in one graph and the solve is UNSAT — §13.2's "one concrete package
    # instance per solved package node", met head on. An implementation that
    # answered this workspace with one graph would have to be answering a
    # DIFFERENT question.
    let reg = startRegistry("prop2-control")
    try:
      var failed = false
      var message = ""
      try:
        discard reg.solveUnified(workspace(), lsHighest)
      except CatchableError as err:
        failed = true
        message = err.msg
      check failed
      check message.len > 0
      # Assert on the CONTENT of the failure, not merely on failure. A
      # generation can fail for a dozen reasons that have nothing to do with
      # the constraint union — a 404 from the registry looked exactly like
      # this while these tests were being written — and a bare `check failed`
      # would have accepted that as evidence for a claim about the solver.
      checkpoint("unified solve reported: " & message)
      check "no satisfying assignment exists" in message
    finally:
      reg.shutdown()
