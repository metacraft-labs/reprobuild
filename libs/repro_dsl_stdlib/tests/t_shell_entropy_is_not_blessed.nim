## A `bash <script>` build edge is NOT entropy-blessed, and this file is the
## guard that keeps it that way.
##
## # Why a test for a tool that is deliberately left alone
##
## `t_nim_entropy_blessing.nim` asserts that `nim` IS blessed and that `gcc`
## is not. This file is its counterpart for the one tool the campaign was
## repeatedly asked to bless: the shell. The request is reasonable on its
## face -- CodeTracer's ten `bash <script>` gate edges publish no cache entry
## purely because an `mrNonDeterministic` record lands in their captures --
## and it is wrong, for a reason that is only visible once the records are
## MEASURED rather than reasoned about. The measurement is recorded here so
## the next person to reach for the blessing meets it first.
##
## # What was measured
##
## io-mon @87143d62, Linux `linux-preload-hooks` backend and Windows
## `windows-interpose-hooks` backend, `io-mon run --depfile ... -- bash
## <script>` then `io-mon inspect ... --format text`:
##
##   * `bash` itself emits ZERO `mrNonDeterministic` records. `bash -c 'echo
##     hello'` produces none on either platform; neither does MSYS bash under
##     `msys-2.0.dll`, which refutes the "the Cygwin runtime seeds itself at
##     startup" theory the blessing request rested on.
##
##   * `$RANDOM` emits ZERO records. A script whose entire output is
##     `echo $RANDOM > out.txt` is genuinely unreproducible and leaves NO
##     entropy evidence at all, on Linux and on MSYS Windows alike -- bash's
##     `$RANDOM` is an internal LCG seeded from the clock and the pid, and it
##     touches no entropy source. So the entropy signal is NOT what protects
##     against script-level non-determinism, and blessing the shell cannot be
##     defended as "waiving a signal that was never load-bearing".
##
##   * Every record a gate action actually emits comes from a CHILD program
##     the script chose to run. Across CodeTracer's ten gates at 996f9b12:
##     45 records, all `path=getrandom`, all attributed by their own pids to
##     `.../bin/mktemp` (23) and `.../bin/git` (22) -- never to the shell. On
##     Windows the same shape: `bash` running `mktemp` reports `ProcessPrng`
##     + `RtlGenRandom` from `mktemp.exe`'s pid, not from bash's.
##
## # Why that forbids the blessing
##
## The engine's policy is ACTION-scoped (`BuildAction.nonDeterminism`) while
## the evidence is PROCESS-TREE-scoped. For a compiler the two coincide: the
## tree under `nim` is nim, gcc and ld, all of it "what nim does", so a
## blessing on nim is a claim about nim. For an interpreter they come apart
## completely -- the set of programs under `bash` is chosen by the SCRIPT,
## not by the tool -- and because bash contributes no records of its own, a
## shell blessing is a waiver that covers ONLY other people's programs.
##
## Measured, that waiver is not theoretical. These two records differ in no
## field except the emitting pid:
##
##     non-deterministic pid=1650509 path=getrandom
##       detail=non-deterministic entropy source
##       [mktemp -- names a scratch file, then throws the name away]
##     non-deterministic pid=1650533 path=getrandom
##       detail=non-deterministic entropy source
##       [uuidgen -- the drawn bytes ARE the declared output]
##
## A blessing that waives the first waives the second, so a gate that grew a
## `uuidgen > out.txt` line would publish a cache entry for a product that is
## different on every run. Uncacheable is safe; falsely-cacheable is not.
##
## (A third measured case shows the signal is not even a complete backstop:
## `od -An -N8 -tx1 /dev/urandom > out.txt` emits NO `mrNonDeterministic`
## record at all -- io-mon deliberately does not flag a /dev/urandom OPEN,
## because mktemp opens it on essentially every build -- and its output is
## random bytes. One more reason the signal must not be spent.)
##
## # What the right mechanism is
##
## Bless the tool that actually emitted -- `mktemp`, `git` -- in ITS own CLI
## spec, which is the stated model ("bless nonDeterminism based on domain
## knowledge of the invoked tool") read correctly: the invoked tool is the
## child that drew the randomness, not the shell that forked it. That needs
## plumbing this milestone does not have. `EntropyObservation` records
## `source` and `origin` and drops `MonitorRecord.osPid`, so the engine
## cannot tell which image in the tree emitted, even though io-mon reports it
## and the `mrProcessExec` records in the same capture name every pid's
## image.
##
## Until that exists, a shell gate stays uncacheable. That is the correct
## outcome, not a gap.
##
## # One more measured trap, for whoever tries anyway
##
## A blessing written in `sh.nim`'s `cli:` block does NOT reach the gate
## edges. Measured: with `nonDeterminism entropyBlessed` added there, the
## GENERATED wrapper `sh(command = ..., args = ...)` comes back
## `ndpEntropyBlessed` while `shell()` -- the proc every gate goes through --
## stays `ndpUnblessed`, because the blessing is spliced into the generated
## wrapper's `recordToolInvocation` call and `shell()` is hand-written and
## calls `recordToolInvocation` without one. It is the same route
## `dependencyPolicy` already fails to survive for `nim.c`. So the blessing
## looks like it "did not take", and the next move is to repair the plumbing
## -- which is how the unsound waiver would actually get made. Both wrappers
## are therefore asserted separately below.

import std/[os, unittest]

import repro_project_dsl
# Aliased for the same reason `t_nim_entropy_blessing.nim` aliases: the
# `package sh:` / `package bash:` blocks emit consts named `sh` and `bash`,
# and a plain `import` would shadow them with the module name.
import repro_dsl_stdlib/packages/sh as sh_module
import repro_dsl_stdlib/packages/bash as bash_module
import repro_dsl_stdlib/packages/nim as nim_module

const shTool = sh_module.sh
const bashTool = bash_module.bash
const nimTool = nim_module.nim

suite "a bash gate edge is not entropy-blessed":

  test "a `bash <script>` shell edge is unblessed and quotes no reason":
    ## The property under test, in the exact shape CodeTracer's ten gates use
    ## (`repro.nim`'s `ctShell`, which is `shell(command = "bash ...")`).
    ##
    ## `shell()` is HAND-WRITTEN and calls `recordToolInvocation` itself, so
    ## the only thing that can bless it is an argument added on that call.
    ## The `cli:` block above cannot: measured, adding `nonDeterminism
    ## entropyBlessed` there leaves this edge at `ndpUnblessed` and blesses
    ## only the generated wrapper the next test covers.
    resetBuildActionRegistry()
    let gate = sh_module.shell(
      command = "bash ci/test/flake-pin-alignment-test.sh",
      actionId = "codetracer.gate.flake-pin-alignment",
      cacheable = true)
    check gate.nonDeterminism == ndpUnblessed
    check gate.nonDeterminismJustification.len == 0

  test "the generated `sh` wrapper is unblessed too":
    ## The SECOND route into the same tool, and the one a `cli:`-block
    ## blessing actually travels. Both are asserted because a blessing
    ## written in `sh.nim` reaches this wrapper and NOT `shell()`, so either
    ## assertion alone leaves half the tool open -- and this is the half
    ## whose silence would be read as "the blessing did not take".
    resetBuildActionRegistry()
    let direct = shTool(command = "echo hi", args = @[])
    check direct.nonDeterminism == ndpUnblessed
    check direct.nonDeterminismJustification.len == 0

  test "nim IS blessed, so the assertions above are about the shell":
    ## The distinguishing control. Without it every check in this file would
    ## pass against an implementation in which the blessing never reaches any
    ## edge at all -- which is how a guard becomes decoration.
    resetBuildActionRegistry()
    let compile = nimTool.c(
      source = "src" / "hello.nim",
      binary = "build" / "bin" / "hello")
    check compile.nonDeterminism == ndpEntropyBlessed

  test "a shell edge cannot bless itself":
    ## The rule the milestone was given -- "this blessing will be done in the
    ## CLI spec of the program, not on the edge definition" -- applied to the
    ## tool most likely to be asked for it. `shell()` is a HAND-WRITTEN
    ## wrapper rather than a generated one, so it does not inherit the
    ## generated wrappers' guard and needs its own. Asserted at COMPILE TIME,
    ## because that is where the guarantee lives: if the proc ever grew the
    ## formal, this would start compiling and a recipe author could vouch for
    ## every program any script of theirs happens to fork.
    check not compiles(sh_module.shell(
      command = "bash ci/test/flake-pin-alignment-test.sh",
      nonDeterminism = ndpEntropyBlessed))

  test "`bash` has no CLI surface for a blessing to live on":
    ## `packages/bash.nim` is PROVISIONING-ONLY: it declares how to obtain a
    ## bash binary and no `executable`/`cli:` block, so there is no
    ## `bash(...)` edge form and nowhere for `nonDeterminism entropyBlessed`
    ## to be written. A blessing added there would compile and reach nothing;
    ## the tool identity of a `bash <script>` edge is `sh` (`shell()` emits
    ## `publicCliCall("sh", "sh", ...)`).
    ##
    ## This reddens the day someone gives `bash` an executable block -- which
    ## is exactly the moment the module docs above need to be read.
    check not compiles(bashTool(command = "echo hi"))
    check not compiles(bashTool.c(source = "x", binary = "y"))
