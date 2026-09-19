## A compiler that CRASHES has not reported a compile error.
##
## The two arrive through the same channel -- a non-zero exit status -- and
## reprobuild treated them identically: raise, abort the command, print
## ``command failed (-1073741819)``. Both halves of that are wrong.
##
## The number is wrong as a diagnostic. ``-1073741819`` is ``0xC0000005``
## sign-extended, because Windows delivers an unhandled fault AS the process
## exit code and ``getExitCodeProcess`` fills an ``int32``. A reader who sees
## it goes looking for the compile error that explains it, and there is none.
##
## Aborting is wrong as a response. A compiler that exits 1 has said something
## about the recipe and will say it again; a compiler that faults has said
## nothing about the recipe at all, so the question is still open.
##
## Measured on this workstation, which is what motivated the distinction:
## ``nim c`` printed its own ``[SuccessX]`` line -- the compile had finished
## and the provider binary was written and runnable -- and the process then
## exited ``0xC0000005``. Because Agent Harbor's ``Justfile`` sets
## ``windows-shell`` to ``repro exec``, every recipe line is a fresh nested
## ``repro``, so a crash rate that is survivable once is a near-certain abort
## somewhere across a multi-recipe run.
##
## The retry predicate is deliberately narrower than the crash predicate, and
## the cases below pin the gap: an externally terminated process must NOT be
## restarted, and a deterministic load-time failure must not be paid for
## twice.

import std/[strutils, unittest]

import repro_interface_artifacts

suite "abnormal termination is distinguished from a failing exit":

  test "an ordinary exit is not a crash, however it ended":
    # The compile-error case, which must keep flowing through unchanged.
    check abnormalTerminationName(0) == ""
    check abnormalTerminationName(1) == ""
    check abnormalTerminationName(2) == ""
    check abnormalTerminationName(127) == ""

  test "an ordinary exit is never retried":
    check not compilerCrashIsRetryable(0)
    check not compilerCrashIsRetryable(1)

when defined(windows):
  suite "Windows delivers faults as the exit code":

    test "the observed access violation is named, not printed as a number":
      # -1073741819 is how 0xC0000005 reaches `waitForExit`, and it is the
      # exact status this workstation produced.
      let name = abnormalTerminationName(-1073741819)
      check name.len > 0
      check "0xC0000005" in name
      check "access violation" in name

    test "the faults that are worth another attempt are retried":
      check compilerCrashIsRetryable(-1073741819)          # 0xC0000005
      check compilerCrashIsRetryable(cast[int](0xC000001D'i32))  # illegal insn
      check compilerCrashIsRetryable(cast[int](0xC00000FD'i32))  # stack ovf
      check compilerCrashIsRetryable(cast[int](0xC0000409'i32))  # fast fail

    test "an unrecognised NTSTATUS error is still a crash":
      # The table cannot be exhaustive, and a status it does not name must
      # still not be mistaken for a compile error.
      let name = abnormalTerminationName(cast[int](0xC0000007'i32))
      check name.len > 0
      check "abnormal termination" in name
      check compilerCrashIsRetryable(cast[int](0xC0000007'i32))

    test "Ctrl+C is not retried":
      # Somebody asked this to stop. Starting it again overrides them.
      check abnormalTerminationName(cast[int](0xC000013A'i32)).len > 0
      check not compilerCrashIsRetryable(cast[int](0xC000013A'i32))

    test "a load-time failure is not retried":
      # Deterministic properties of the installation: a second attempt buys a
      # guaranteed second failure and doubles the wait before the operator
      # sees the real diagnostic.
      for status in [0xC0000135'i32, 0xC0000139'i32, 0xC0000142'i32]:
        checkpoint("status 0x" & $status)
        check abnormalTerminationName(cast[int](status)).len > 0
        check not compilerCrashIsRetryable(cast[int](status))

    test "a success-severity status is not a crash":
      # Only the `error` severity nibble means the process died; a positive
      # small exit code must not be reinterpreted.
      check abnormalTerminationName(3) == ""

else:
  suite "POSIX reports a signalled child as 128 + signal":

    test "a fatal fault is named":
      check "SIGSEGV" in abnormalTerminationName(128 + 11)
      check "SIGILL" in abnormalTerminationName(128 + 4)
      check "SIGABRT" in abnormalTerminationName(128 + 6)

    test "a fatal fault is retried":
      check compilerCrashIsRetryable(128 + 11)
      check compilerCrashIsRetryable(128 + 6)

    test "external termination is not retried":
      # SIGKILL is usually the OOM killer; re-entering the compile re-enters
      # whatever exhausted the machine.
      for sig in [2, 9, 15]:
        checkpoint("signal " & $sig)
        check abnormalTerminationName(128 + sig).len > 0
        check not compilerCrashIsRetryable(128 + sig)

    test "an out-of-range status is not read as a signal":
      check abnormalTerminationName(128) == ""
      check abnormalTerminationName(128 + 65) == ""
