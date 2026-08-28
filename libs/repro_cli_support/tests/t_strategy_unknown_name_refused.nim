## An unknown `--strategy` errors and lists the valid ones.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-6**: "An unknown strategy
## errors and lists the valid ones, rather than being silently dropped."
##
## ## Why "lists the valid ones" is part of the requirement
##
## A refusal that says only "unknown strategy" leaves the caller to guess, and
## guessing is how a typo becomes a silently-different build: the natural next
## attempt is to drop the flag, which is the `default` strategy — the exact
## outcome the refusal existed to prevent. So the diagnostic is asserted to
## name every accepted spelling, and the list is checked against the enum
## rather than against a hand-written expectation, so a strategy added later
## cannot be accepted while going unlisted.
##
## ## Silently dropped is the failure being kept out
##
## The corpus wording — "rather than being silently dropped" — names the shape:
## an argument parser that ignored what it did not recognise would return 0 and
## build under `default`. So the exit code is asserted too, and asserted to be
## the USAGE code (2) rather than merely non-zero, so a crash on the way to the
## diagnostic would not read as a refusal.
##
## ## How the diagnostic is read, and why in two ways
##
## The message text is asserted against `unknownStrategyDiagnostic`, the
## exported builder both CLI call sites use — so the assertion is over the
## exact string the CLI writes, on every platform, with no capture involved.
##
## Separately, and only on POSIX, the dispatcher's own stderr is redirected
## with `dup2` so the test can confirm the CLI actually EMITS that string
## rather than merely being able to build it. `reopen(stderr, …)` was tried
## first and silently captured nothing — it returns success and the writes go
## elsewhere — which is exactly the kind of check that looks like evidence and
## is not, so it is recorded here rather than left as a dead end someone
## repeats.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The real `runReproLockCommand` dispatcher runs with real argument vectors
## and the real message builder produces the real text. The only substitution
## is the process's own stderr file descriptor, and only for the duration of
## one call.

import std/[os, strutils, unittest]

when defined(posix):
  import std/posix

import repro_cli_support
import repro_lock_gen

proc runCapturingStderr(args: openArray[string]): tuple[rc: int; err: string] =
  ## Run `repro lock <args>`, capturing stderr on POSIX.
  ##
  ## The redirection is at the FILE DESCRIPTOR, not on Nim's `stderr` handle:
  ## the diagnostic is emitted by `stderr.writeLine` deep inside the CLI, and a
  ## writer parameter would require the CLI to grow a seam that exists only for
  ## this test. Descriptor 2 is restored before returning, so the rest of the
  ## suite still reports normally.
  ##
  ## On non-POSIX hosts `err` is empty and the callers below skip the text
  ## assertions; the exit-code assertions and the `unknownStrategyDiagnostic`
  ## assertions run everywhere.
  when defined(posix):
    let capture = getTempDir() / ("repro-nlf-strat6-" &
      $getCurrentProcessId() & ".err")
    let saved = dup(2)
    let fd = open(capture.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
    doAssert fd >= 0
    doAssert dup2(fd, 2) >= 0
    discard close(fd)
    try:
      result.rc = runReproLockCommand(args)
    finally:
      stderr.flushFile()
      discard dup2(saved, 2)
      discard close(saved)
    result.err = if fileExists(capture): readFile(capture) else: ""
    removeFile(capture)
  else:
    result.rc = runReproLockCommand(args)
    result.err = ""

suite "NLF-STRAT-6 an unknown strategy is refused":

  test "the exit code is the usage code, not success and not a crash":
    let outcome = runCapturingStderr(["solve", "--strategy", "loweset"])
    check outcome.rc == 2

  test "the diagnostic names the offending value":
    let message = unknownStrategyDiagnostic("repro lock solve", "loweset")
    check message.contains("loweset")
    check message.contains("unknown --strategy")

  test "the diagnostic lists EVERY accepted strategy":
    let message = unknownStrategyDiagnostic("repro lock solve", "loweset")
    for strategy in LockStrategy:
      check message.contains($strategy)

  test "the dispatcher actually emits that diagnostic":
    # The builder above could be correct and unused. This runs the real
    # dispatcher and reads what it wrote.
    when defined(posix):
      let outcome = runCapturingStderr(["solve", "--strategy", "loweset"])
      check outcome.rc == 2
      check outcome.err.contains(
        unknownStrategyDiagnostic("repro lock solve", "loweset"))
    else:
      skip()

  test "the advertised list and the accepted set are the same set":
    # Derived from the enum on both sides. The previous shape repeated the
    # list inside two separate diagnostics, so adding `lowest-direct` to the
    # parser would have left both messages advertising three strategies while
    # four were accepted — a message that is wrong in the direction that makes
    # a working spelling look invalid.
    for strategy in LockStrategy:
      check LockStrategyNames.contains($strategy)
    var advertised = 0
    for part in LockStrategyNames.split(","):
      if part.strip().len > 0: inc advertised
    var accepted = 0
    for strategy in LockStrategy: inc accepted
    check advertised == accepted

  test "every accepted spelling is in fact accepted":
    # The other direction: a name the diagnostic advertises must parse. Run
    # against a project directory that has no solver inputs, so the command
    # fails LATER (rc 1, "no solver inputs found") rather than at argument
    # parsing (rc 2) — which is what distinguishes "the strategy was accepted"
    # from "the command happened to succeed".
    let empty = getTempDir() / ("repro-nlf-strat6-empty-" &
      $getCurrentProcessId())
    createDir(empty)
    try:
      for strategy in LockStrategy:
        let outcome = runCapturingStderr(
          ["solve", empty, "--strategy", $strategy])
        check outcome.rc != 2
        when defined(posix):
          check not outcome.err.contains("unknown --strategy")
    finally:
      removeDir(empty)

  test "the sugar flags are accepted and are not mistaken for unknown flags":
    let empty = getTempDir() / ("repro-nlf-strat6-sugar-" &
      $getCurrentProcessId())
    createDir(empty)
    try:
      for flag in ["--lowest", "--highest"]:
        let outcome = runCapturingStderr(["solve", empty, flag])
        check outcome.rc != 2
        when defined(posix):
          check not outcome.err.contains("unknown flag")
    finally:
      removeDir(empty)

  test "an unknown flag is still refused, so acceptance is not universal":
    let outcome = runCapturingStderr(["solve", "--lowestish"])
    check outcome.rc == 2
    when defined(posix):
      check outcome.err.contains("unknown flag")
