## DA-6 — the tool packages' capture-breadth declarations, read off REAL edges,
## and checked against the consumers they are allowed to narrow away.
##
## # What this file is for
##
## `libs/repro_build_engine/tests/t_da6_declared_interest_keeps_every_consumer.nim`
## grades the VOCABULARY: no word a tool package can write drops a category some
## reprobuild consumer reads. This file grades the DECLARATIONS: that each tool
## package actually made one, that it made the one its own comment argues for,
## and that the declaration reaches a real registered edge rather than stopping
## at the parser.
##
## Two halves, in two libraries, and nothing in the compiler ties them together
## — which is precisely the shape `t_entropy_image_blessings.nim` exists for on
## the entropy axis. The declaration is DSL text compiled into a recipe provider
## (`repro_dsl_stdlib`); the thing that acts on it is
## `monitorInterest` / `declaredMonitorInterest` (`repro_build_engine`). This
## file is in `tests/integration` because it is the only layer that can import
## both and therefore the only place the two can be compared.
##
## # Why reading a declaration back is not enough, and what is checked instead
##
## A test that asserts `nim.c(...)` declares `mcbOmitAmbientReads` is satisfied
## by a typo-free copy of the wrong answer. So every per-tool case here asserts
## the declaration TOGETHER WITH the property that makes it sound, in the
## vocabulary of the consumer that would be harmed:
##
##   * for every tool, whatever it declared must still ask for `ecEnvReads` and
##     `ecEntropy` — `cacheEnvInputs` and `applyEntropyBlessingPolicy` — so a
##     declaration edited to drop either reddens here naming them;
##   * for every ENTROPY-BLESSED tool the entropy requirement is stated a second
##     time and separately, because on those tools the failure is not "records
##     missing" but "the blessing has nothing to be applied to": the gate then
##     sees `entropyObservability == entObserved` with zero observations, which
##     is the false clean it exists to refuse;
##   * `nim`'s narrowing is checked on BOTH of its routes (`nim.c`, which takes
##     its policy through the hand-written alias, and the generated wrapper,
##     which takes it from the `cli:` block), because those routes are known to
##     carry declarations differently — `dependencyPolicy` does not survive to
##     `nim.c` at all, which is why the declaration is written twice;
##   * `sh`'s full capture is checked on both of ITS routes (`shell()`, which is
##     hand-written, and the generated `sh(...)` wrapper) for the same reason.
##
## # The negative controls
##
## `nim` NARROWS and `gcc` does NOT. Both halves are asserted, and the pairing
## is what makes either meaningful: a test suite in which every tool declares
## the same thing grades nothing about the per-tool reasoning DA-6 is made of,
## and would pass unchanged against a design that put one constant back in the
## engine.
##
## # Mocks
##
## NONE. Every edge here is produced by the real package macros through the real
## typed-tool wrappers and read off a registered `BuildActionDef`; the interest
## sets come from the engine's own `declaredMonitorInterest`. The only
## indirection is `resetBuildActionRegistry()` before each edge, which is how
## every other DSL-stdlib test isolates registrations.

import std/[strutils, unittest]

import repro_build_engine
import repro_core
import repro_project_dsl
import io_mon

# Aliased for the reason `t_nim_entropy_blessing.nim` gives: each `package`
# block emits a const named after the package, and a plain `import` would shadow
# it with the module name.
import repro_dsl_stdlib/packages/nim as nim_module
import repro_dsl_stdlib/packages/gcc as gcc_module
import repro_dsl_stdlib/packages/clang as clang_module
import repro_dsl_stdlib/packages/sh as sh_module
import repro_dsl_stdlib/packages/git as git_module
import repro_dsl_stdlib/packages/mktemp as mktemp_module

{.experimental: "callOperator".}

const nimTool = nim_module.nim
const gccTool = gcc_module.gcc
const clangTool = clang_module.clang
const shTool = sh_module.sh
const gitTool = git_module.git
const mktempTool = mktemp_module.mktemp

proc declaredBreadth(edge: BuildActionDef): MonitorCaptureBreadth =
  edge.dependencyPolicy.captureBreadth

proc asked(edge: BuildActionDef): set[EventCategory] =
  ## What io-mon would be asked for, computed by the ENGINE's own mapping from
  ## the declaration this edge carries. Going through `declaredMonitorInterest`
  ## rather than restating the two sets here is the point of the file: the
  ## comparison is between what the tool package said and what the engine will
  ## do about it.
  declaredMonitorInterest(edge.declaredBreadth)

proc nimCompileEdge(): BuildActionDef =
  resetBuildActionRegistry()
  nimTool.c(source = "src/hello.nim", binary = "build/bin/hello")

proc nimJsEdge(): BuildActionDef =
  resetBuildActionRegistry()
  nimTool.js(source = "src/hello.nim", output = "build/hello.js")

proc gccEdge(): BuildActionDef =
  resetBuildActionRegistry()
  gccTool(source = "src/a.c", output = "build/a.o", compileOnly = true)

proc clangEdge(): BuildActionDef =
  resetBuildActionRegistry()
  clangTool(source = "src/a.c", output = "build/a.o", compileOnly = true)

proc shellEdge(): BuildActionDef =
  resetBuildActionRegistry()
  sh_module.shell(command = "bash scripts/gate.sh",
    actionId = "da6.gate", cacheable = true)

proc generatedShEdge(): BuildActionDef =
  resetBuildActionRegistry()
  shTool(command = "echo da6", args = @[])

proc gitEdge(): BuildActionDef =
  resetBuildActionRegistry()
  gitTool(args = @["status", "--porcelain"])

proc mktempEdge(): BuildActionDef =
  resetBuildActionRegistry()
  mktempTool(args = @["-d"])

proc everyDeclaredEdge(): seq[(string, BuildActionDef)] =
  @[("nim.c", nimCompileEdge()),
    ("nim.js", nimJsEdge()),
    ("gcc", gccEdge()),
    ("clang", clangEdge()),
    ("shell()", shellEdge()),
    ("sh (generated wrapper)", generatedShEdge()),
    ("git", gitEdge()),
    ("mktemp", mktempEdge())]

suite "DA-6 no tool's declaration costs a consumer its evidence":

  test "every declared tool still asks for every consumed category":
    ## THE ONE CASE THAT WOULD CATCH A BAD DECLARATION IN ANY TOOL PACKAGE, and
    ## it is written over the tools rather than over the vocabulary on purpose:
    ## the engine-side file already proves no WORD can drop a consumed category,
    ## so what is left to get wrong here is a tool declaring a word that did not
    ## exist when that proof was written.
    for (name, edge) in everyDeclaredEdge():
      for category in ReprobuildConsumedInterest:
        if category notin edge.asked:
          echo "TOOL `", name, "` declares `", edge.declaredBreadth,
            "`, which does not ask io-mon for `", interestToken(category),
            "` — records read by ", interestConsumer(category), ".",
            "\n  The capture would come back without that evidence and still ",
            "grade mcComplete: a false cache hit."
        check category in edge.asked

  test "no tool's declaration drops the env reads that key its action":
    ## Stated separately from the loop above, and named, because this is the
    ## consumer a narrowing is most tempting for: env reads look like noise
    ## (`PWD`, `PATH`, `TERM`) right up to the moment one of them is
    ## `SOURCE_DATE_EPOCH`. `cacheEnvInputs` folds every `mrEnvRead` into the
    ## action's STRONG FINGERPRINT, so an action whose capture lost them keys
    ## identically for every value of them — the false-hit class the observed-env
    ## cache key exists to close.
    check interestConsumer(ecEnvReads).contains("cacheEnvInputs")
    for (name, edge) in everyDeclaredEdge():
      if ecEnvReads notin edge.asked:
        echo "TOOL `", name, "` stopped asking for env reads; ",
          interestConsumer(ecEnvReads), " will key its action on nothing."
      check ecEnvReads in edge.asked

  test "no tool's declaration drops the entropy that gates its publication":
    ## The other named consumer. `applyEntropyBlessingPolicy` decides whether an
    ## action publishes, and it decides it by READING `mrNonDeterministic`
    ## records. A declaration that dropped `ecEntropy` leaves it zero
    ## observations while `entropyObservability` still says `entObserved` — the
    ## backend-profile record is META and is never gated — so it publishes.
    check interestConsumer(ecEntropy).contains("applyEntropyBlessingPolicy")
    for (name, edge) in everyDeclaredEdge():
      if ecEntropy notin edge.asked:
        echo "TOOL `", name, "` stopped asking for entropy; ",
          interestConsumer(ecEntropy), " will see `observable, and nothing ",
          "observed` and PUBLISH."
      check ecEntropy in edge.asked

suite "DA-6 a blessed tool keeps the evidence its blessing is applied to":

  test "every entropy-blessed tool still asks for the entropy category":
    ## THE BLESSED NON-DETERMINISTIC CASE DA-6 SINGLES OUT, and the direction of
    ## the failure is what makes it its own case rather than a repeat of the
    ## loop above.
    ##
    ## On an UNBLESSED tool, losing `ecEntropy` loses a reason to withhold
    ## publication. On a BLESSED one it is worse in a way that reads as
    ## correct: the blessing is still declared, still carries its
    ## justification, still round-trips — and has nothing to be applied to,
    ## because `applyEntropyBlessingPolicy` resolves each observation's emitting
    ## image against the capture's own `mrProcessExec` records and asks whether
    ## THAT tool is blessed. No observations, no attribution, and the gate sees
    ## "observable, and nothing observed". A narrowing here removes exactly the
    ## evidence the blessing reads, which is why the tools this campaign blessed
    ## (`nim`, `git`, `mktemp`) are checked here by their blessing rather than by
    ## their name: a tool blessed LATER is covered the day it is blessed.
    var blessedSeen = 0
    for (name, edge) in everyDeclaredEdge():
      if edge.nonDeterminism != ndpEntropyBlessed:
        continue
      inc blessedSeen
      if ecEntropy notin edge.asked:
        echo "BLESSED TOOL `", name, "` declares `", edge.declaredBreadth,
          "`, which does not ask for `", interestToken(ecEntropy), "`. Its ",
          "blessing (\"", edge.nonDeterminismJustification[0 ..<
            min(60, edge.nonDeterminismJustification.len)],
          "…\") is now unreachable rather than revoked: ",
          interestConsumer(ecEntropy), " sees zero observations and publishes."
      check ecEntropy in edge.asked
      check ecProcessTree in edge.asked
    # The anti-vacuity control: if the blessings ever stop reaching these edges
    # the loop body never runs and the case passes without checking anything.
    # Three tools are blessed today (nim on both routes, git, mktemp).
    check blessedSeen >= 3

suite "DA-6 the per-tool declarations are the ones the packages argue for":

  test "nim NARROWS, on both of its routes":
    ## `nim c` emits no depfile, so monitoring is the only source of its input
    ## set and the capture is the campaign's class-1 cost (one measured full
    ## monitored `nim c` produced 25 206 records). Nothing about nim's own
    ## irreproducibility is witnessed by a clock or a sysctl read — its
    ## randomness is entropy, which it keeps and is blessed for, and its temp
    ## names derive from the argv — so `ecAmbientReads` is the one category it
    ## can decline.
    ##
    ## BOTH ROUTES, because they carry declarations differently and one
    ## assertion would leave the other open: the `dependencyPolicy` written in
    ## `nim.nim`'s `cli:` block does NOT survive to a `nim.c` edge (the
    ## hand-written alias routes through `compileDependencyPolicy`, which builds
    ## a fresh value), which is why `nim.nim` states the declaration twice. If
    ## someone "tidies up" the duplicate, this is the case that reddens.
    check nimCompileEdge().declaredBreadth == mcbOmitAmbientReads
    check nimJsEdge().declaredBreadth == mcbOmitAmbientReads
    check ecAmbientReads notin nimCompileEdge().asked
    check ecAmbientReads notin nimJsEdge().asked
    # And what it did NOT give up. Stated here rather than left to the loops
    # above so the narrowing and its scope are legible in one place.
    check ReprobuildConsumedInterest <= nimCompileEdge().asked

  test "gcc and clang DECLINE the narrowing":
    ## THE NEGATIVE CONTROL, and the case that makes the one above mean
    ## something: with both arms narrowing, this suite would pass against a
    ## design that put a single constant back in the engine and threw the
    ## per-tool reasoning away.
    ##
    ## gcc/clang `-MD` emit their own dependency list, so the depfile is primary
    ## and monitoring is the CROSS-CHECK for what a `.d` file structurally
    ## cannot contain. `__DATE__` / `__TIME__` / `__TIMESTAMP__` are these
    ## tools' signature irreproducibility, they are a clock read, and
    ## `mrTimeRead` is the only record that witnesses one — so the narrowing
    ## that is available on nim would delete, on gcc, the only evidence of gcc's
    ## best-known reproducibility bug. Reprobuild has no consumer for it today
    ## and the packages say so; this is the fail-closed choice, taken at a
    ## measured 2.2% of records.
    check gccEdge().declaredBreadth == mcbFullCapture
    check clangEdge().declaredBreadth == mcbFullCapture
    check ecAmbientReads in gccEdge().asked
    check ecAmbientReads in clangEdge().asked
    check gccEdge().asked == FullInterest
    check clangEdge().asked == FullInterest

  test "the shell declines it too, on both of ITS routes":
    ## `sh` guarantees NOTHING about what runs under it. A capture-breadth
    ## declaration is a claim about a tool's process tree, and for an
    ## interpreter the tree is chosen by the SCRIPT — so there is no category
    ## `sh` is entitled to vouch for. This is the same argument, one axis over,
    ## that `sh.nim` already makes for refusing the entropy blessing.
    ##
    ## It is also where a `nix build` edge's declaration lands: `nix build` in a
    ## recipe is a `shell()` edge, `packages/nix.nim` is provisioning-only, and
    ## "hermetic, therefore do not look" is the argument that makes the
    ## hermeticity unfalsifiable — the records that would witness a breach
    ## (`NIX_PATH` env reads, `/etc/nix/nix.conf`, the daemon hand-off, an outer
    ## clock read) are exactly the ones a narrowing removes.
    ##
    ## BOTH ROUTES: `shell()` is hand-written and defaults its own
    ## `dependencyPolicy`, so what the `cli:` block says reaches only the
    ## generated `sh(...)` wrapper. Every CodeTracer gate goes through
    ## `shell()`.
    check shellEdge().declaredBreadth == mcbFullCapture
    check generatedShEdge().declaredBreadth == mcbFullCapture
    check shellEdge().asked == FullInterest
    check generatedShEdge().asked == FullInterest

  test "the blessed helpers decline it, and their blessings say why":
    ## `git` and `mktemp` are blessed for ENTROPY and for nothing else, and both
    ## justifications name the exception out loud: a commit object's hash
    ## depends on its committer TIMESTAMP, which is a clock read the engine does
    ## not grade. `mrTimeRead` is the only witness of the part that is NOT
    ## blessed, so dropping `ecAmbientReads` on these two would delete the
    ## evidence of the exception while keeping the waiver — a narrowly-scoped
    ## blessing turning into a broad one with nobody editing the blessing.
    check gitEdge().declaredBreadth == mcbFullCapture
    check mktempEdge().declaredBreadth == mcbFullCapture
    check ecAmbientReads in gitEdge().asked
    check ecAmbientReads in mktempEdge().asked
    # The link between the declaration and the reason for it: the blessing these
    # tools carry is the one that excludes the clock.
    check "ENTROPY only" in gitEdge().nonDeterminismJustification
    check "mrTimeRead" in gitEdge().nonDeterminismJustification

  test "the declarations are not all the same value":
    ## The anti-uniformity control for the whole file. DA-6's thesis is that the
    ## answer is per-tool; if every tool ends up declaring the same word then
    ## nothing here is a declaration and the milestone reduced to a rename.
    var breadths: set[MonitorCaptureBreadth] = {}
    for (_, edge) in everyDeclaredEdge():
      breadths.incl(edge.declaredBreadth)
    check breadths == {mcbFullCapture, mcbOmitAmbientReads}

suite "DA-6 the declaration survives the lowering into a BuildAction":

  test "a lowered nim.c action asks io-mon for what the package declared":
    ## Every case above reads the declaration off a `BuildActionDef` — the DSL's
    ## value. What the monitor is actually asked for is decided by
    ## `monitorInterest` over a lowered `BuildAction`, so this case pins the
    ## ENGINE end: given the breadth the package declared, the interest set is
    ## the narrowed one. It is checked for the tool whose declaration is the
    ## NON-DEFAULT one, because a full-capture tool's assertion is satisfied by
    ## any answer that happens to be `FullInterest`.
    ##
    ## WHAT THIS CASE DOES NOT COVER, stated because an earlier version of this
    ## comment claimed it did and that claim cost a milestone. The line below
    ## assigns `captureBreadth` by hand, so the DSL->engine TRANSPORT is
    ## performed by the test rather than by production code. That transport is
    ## the `BuildActionDef` payload codec, and while it silently dropped the
    ## field every case in this file still passed — the declaration was
    ## unreachable and nothing here noticed, because nothing here crossed the
    ## hop. The codec is covered by
    ## `libs/repro_dsl_stdlib/tests/t_da6_capture_breadth_dsl_surface.nim`'s
    ## payload round-trip suite; this case is the link on the far side of it.
    let edge = nimCompileEdge()
    var policy = automaticMonitorGatheringPolicy()
    policy.captureBreadth = edge.declaredBreadth
    let lowered = action("da6/nim-c", ["/bin/true"],
      dependencyPolicy = policy,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check monitorInterest(lowered) == FullInterest - {ecAmbientReads}
    check monitorInterest(lowered) == edge.asked
