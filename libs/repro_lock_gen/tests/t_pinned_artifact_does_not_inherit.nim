## NLF-PROP-3 — a pinned artifact keeps its own lock file whoever pulls it in.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-PROP-3**, whose instruction is
## the shape of this file: "**Assert on the resolved version, not on whether
## the tool ran.**"
##
## Design §4.6's table:
##
## | Artifact | Declares `lockFile`? | Behaviour |
## |---|---|---|
## | A build tool that must run on the build machine | `lockFile hostTools` | **Pinned.** Always built under `hostTools`, whoever pulls it in. |
## | An ordinary library | *(nothing)* | **Inherits.** Built under whatever lock file its consumer is under; once per distinct consuming lock file. |
##
## > This is Bazel's `cfg = "exec"` versus the default `cfg = "target"`,
## > reached by the same reasoning: a host tool is host *intrinsically*,
## > whereas a library's architecture is a property of who is using it.
##
## ## Why "assert on the resolved version" is the whole instruction
##
## "Did the pinned tool run" is satisfied by an implementation in which the
## pin is recorded and ignored — the tool runs either way, because it is in
## the graph either way. What the pin CHANGES is which solved graph its
## dependencies come from, and that is visible only in a version.
##
## So `libbar` below is pulled in by three things that disagree about it:
## the host graph wants `<2.0`, the shipped graph wants `>=2.0`, and `codegen`
## — the pinned tool — accepts either. If the pin holds, `codegen`'s `libbar`
## is the host graph's `1.x`. If `codegen` had inherited from its consumer it
## would be the shipped graph's `2.x`, and the tool would have run in both
## cases.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m7_fixture`'s header, which states the policy in full.

import std/[tables, unittest]

import repro_lock_gen

import ./nlf_m7_fixture

const
  App = "app"
  HostShell = "hostshell"
  Codegen = "codegen"
  LibBar = "libbar"
  TargetRuntime = "targetRuntime"
  Published = ["1.1.0", "1.4.0", "2.1.0", "2.5.0"]

proc workspace(): Recipe =
  ## `codegen` PINS `hostTools`. It is consumed only by `app`, which is
  ## designated `targetRuntime` — so if the pin did not hold, `codegen` and
  ## its `libbar` would be in the shipped graph.
  Recipe(
    packages: @[
      RecipePackage(name: App, versions: @["1.0.0"],
        deps: @[dep(Codegen, ">=1.0"), dep(LibBar, ">=2.0 <3.0")]),
      RecipePackage(name: HostShell, versions: @["1.0.0"],
        deps: @[dep(LibBar, ">=1.0 <2.0")]),
      RecipePackage(name: Codegen, versions: @["1.0.0"],
        pinnedLockFile: HostToolsLockFileName,
        deps: @[dep(LibBar, ">=1.0 <3.0")]),
      RecipePackage(name: LibBar, versions: @Published)],
    artifacts: @[
      RecipeArtifact(name: HostShell, package: HostShell,
        lockFile: HostToolsLockFileName),
      RecipeArtifact(name: App, package: App, lockFile: TargetRuntime)])

suite "NLF-PROP-3 a pinned artifact does not inherit":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime, description = "What we ship.")

  test "the pinned package is in the host graph only":
    let prop = propagationOf(workspace())
    check prop.lockFilesByPackage[Codegen] == @[HostToolsLockFileName]
    check prop.instanceCount(Codegen) == 1

  test "the pinned tool's dependency resolves in the HOST graph's range":
    # The assertion NLF-PROP-3 asks for. `codegen` accepts `libbar` anywhere
    # in `>=1.0 <3.0`; which end it gets is decided entirely by which graph it
    # is solved in.
    let reg = startRegistry("prop3")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      let host = solved[HostToolsLockFileName].solvedVersions()
      let target = solved[TargetRuntime].solvedVersions()

      check host.hasKey(Codegen)
      check not target.hasKey(Codegen)

      # The discriminating pair. `1.4.0` is the highest `libbar` the HOST
      # graph admits; `2.5.0` is the highest the shipped graph admits. An
      # implementation in which `codegen` inherited `targetRuntime` would put
      # `codegen` beside a `2.x` libbar, and this line is the only place that
      # shows.
      check host[LibBar] == "1.4.0"
      check target[LibBar] == "2.5.0"
    finally:
      reg.shutdown()

  test "the un-pinned library still inherits, so the pin is not global":
    # The control against "everything is pinned to hostTools". `libbar`
    # declares nothing and is instantiated under BOTH lock files, which is
    # §4.6's second row.
    let prop = propagationOf(workspace())
    check prop.instanceCount(LibBar) == 2
    check prop.lockFilesByPackage[LibBar] ==
      @[HostToolsLockFileName, TargetRuntime]

  test "the pin lives at the dependency, not at the consumer":
    # §4.6: "a use-site override needs no new syntax — 'build this dependency
    # for the host instead' is spelled by designating that dependency's own
    # artifact". `app` says nothing about `codegen`'s lock file; the fact that
    # `codegen` ends up under `hostTools` is entirely `codegen`'s own
    # declaration. §4.6 also names the cost of that — "a reader of the
    # *consuming* recipe cannot see it" — which is why the propagation result
    # can report it at the consumer.
    var appMentionsCodegenLock = false
    for a in workspace().artifacts:
      if a.package == App and a.lockFile == HostToolsLockFileName:
        appMentionsCodegenLock = true
    check not appMentionsCodegenLock
    let prop = propagationOf(workspace())
    check prop.lockFilesByPackage[App] == @[TargetRuntime]
    check prop.lockFilesByPackage[Codegen] == @[HostToolsLockFileName]
