## A preloaded monitor shim never allocates from the host program's allocator.
##
## The shim runs inside programs this repository did not build, and its hooks
## run in whatever state the program was in when it made the call. A program's
## allocator is one of the places such a call comes from: jemalloc, which
## rustc links statically, calls ``clock_gettime`` from ``arena_new`` while it
## holds ``arenas_lock``. The shim's ``clock_gettime`` hook builds its evidence
## record with a Nim string. When the shim took that memory from the host's
## ``malloc`` -- jemalloc's -- the allocation re-entered jemalloc under its own
## non-recursive lock, and rustc hung with every thread in ``futex_wait``:
## v0.2.28 and v0.2.29 release shims, a cargo ``--print=file-names`` probe of
## rustc 1.94. On CI the same action died with SIGSEGV in rustc instead. The
## Nix package's shim did not hang. io-mon's ``scripts/build_shim.sh`` builds
## it with ``-d:ioMonGlibcPrivateHeap``, which links the shim's own allocations
## to a private heap. The ``reprobuild.test_fixtures.monitor_shim`` edge in
## ``repro.nim`` builds the shim the release ships, and it did not pass that
## define.
##
## The subject is ``clock-under-allocator-lock``: a multi-threaded program that
## replaces the C allocator and reads the clock under its allocator lock on
## EVERY allocation. That makes the hazard deterministic: rustc hit it only
## when a thread created an arena, and only in some builds of the shim. The
## program detects a re-entry and exits with status 3 instead of deadlocking.
## A timeout bounds each run anyway, for a hazard of some other shape.
##
## Cases:
##   1. Control, no preload: the program runs clean on its own.
##   2. Negative control: a preload whose ``clock_gettime`` allocates through
##      the host allocator must be caught. Without this case a passing run of
##      case 3 could mean that the program does not detect anything.
##   3. The shim this tree builds -- the artifact the release packages -- runs
##      clean in the program.
##
## Mocks, and why (per the repository policy on justifying every mock): the
## subject program is synthetic. It stands in for jemalloc because it states
## the one property that matters -- the clock is read under the allocator lock
## -- without depending on a Rust toolchain, on jemalloc's arena heuristics or
## on how many CPUs the host has. The control preload is synthetic for the
## same reason. The shim, the dynamic loader, glibc and the threads are real.
##
## Linux only: the private heap is the glibc build of the Linux shim; macOS
## and Windows inject different libraries with their own allocation paths.

import std/[os, strutils, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

const
  SubjectPath = "build/test-fixtures/preload-host-allocator/" &
    "clock-under-allocator-lock"
  SubjectEdge = "reprobuild.test_fixtures.clock_under_allocator_lock"
  ControlPreloadPath = "build/test-fixtures/preload-host-allocator/" &
    "liballocating_clock_hook.so"
  ControlPreloadEdge = "reprobuild.test_fixtures.allocating_clock_hook"
  RunTimeoutMs = 60_000
    ## A healthy run takes milliseconds. The bound only has to be finite, so
    ## that a hang fails this case instead of wedging the suite; it is wide
    ## so a loaded host does not turn slowness into a false failure.
  ExitReentered = 3
    ## ``EXIT_REENTERED`` in ``clock_under_allocator_lock.c``.
  OkLine = "clock_under_allocator_lock: ok"
  ReenteredNeedle = "the allocator was re-entered"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc runSubject(subject, preload: string): CmdResult =
  ## The subject with ``preload`` as its ONLY preload. Anything the test
  ## process inherited (another monitor, a tracer) is dropped, so the run
  ## says something about ``preload`` alone.
  runShell(shellCommand(@[subject], @[("LD_PRELOAD", preload)]),
    timeoutMs = RunTimeoutMs)

proc report(label: string; run: CmdResult) =
  checkpoint(label & ": exit " & $run.code & "\n" & run.output)
  if run.code == runShellTimedOutCode:
    checkpoint(label & ": did not finish within " & $RunTimeoutMs &
      " ms -- the deadlock this file exists for")

suite "a preloaded monitor shim keeps out of the host allocator":

  test "the subject runs clean without a preload":
    when not defined(linux):
      skip("Linux only: the private heap belongs to the glibc build of " &
        "the Linux shim")
    else:
      let subject = requireBinary(graphArtifactPath(SubjectPath), SubjectEdge)
      let run = runSubject(subject, "")
      report("no preload", run)
      check run.code == 0
      check OkLine in run.output

  test "the subject catches a preload that allocates from the host":
    when not defined(linux):
      skip("Linux only: see the first case")
    else:
      let subject = requireBinary(graphArtifactPath(SubjectPath), SubjectEdge)
      let control = requireBinary(graphArtifactPath(ControlPreloadPath),
        ControlPreloadEdge)
      let run = runSubject(subject, control)
      report("allocating control preload", run)
      check run.code == ExitReentered
      check ReenteredNeedle in run.output

  test "the shim this tree builds runs clean in the subject":
    when not defined(linux):
      skip("Linux only: see the first case")
    else:
      let subject = requireBinary(graphArtifactPath(SubjectPath), SubjectEdge)
      let shim = monitorShimPath(repoRoot())
      if not fileExists(shim):
        skip(shim & " is not built; build the " &
          "reprobuild.test_fixtures.monitor_shim edge")
      else:
        let run = runSubject(subject, shim)
        report("monitor shim " & shim, run)
        check ReenteredNeedle notin run.output
        check run.code == 0
        check OkLine in run.output
