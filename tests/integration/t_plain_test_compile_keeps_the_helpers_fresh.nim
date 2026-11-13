## A plain `nim c -r` of a test that runs a guarded helper, after
## `just build`, passes, and leaves both guarded helpers accepted
## (ReproOS Add-On Mode spec §13 decision 86; reprobuild-pm issue
## 2026-11-13-helper-list-root-listing-refuses-the-helpers-after-the-first-
## plain-test-compile).
##
## The checkout's `config.nims` gives a `nim c` without `--nimcache:` a
## nimcache at `<checkout>/.nimcache/`, so the compile below adds that
## directory to the checkout root -- a directory the compiler's package
## search lists while the helpers are built. Under decision 86 only an
## entry that can change what the compiler resolves (a `.nim`, `.nimble`
## or `.nims` file, a directory on the search path) counts in a listing,
## so the helpers stay fresh. Under round 8's digest of every entry they
## were refused by the second run (the issue's run B).
##
## The control: the checkout root's own entries change during the run
## (`.nimcache/` is created when absent), or the test says the run proved
## nothing about it.
##
## Opt-in, as it needs the tree's `just build` output and compiles the sink
## suite: `REPRO_RUN_PLAIN_COMPILE_TEST=1`. Linux only (the helper lists
## are written with strace).
##
## Mocks: none -- the real compiler, the real checkout, the real helpers.

import std/[os, osproc, strutils, unittest]

import repro_test_support/fresh_binary
import repro_test_support/reasoned_skip

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const SinkTest = "libs/repro_peer_cache/tests/t_evidence_sink_append_only_and_liveness.nim"

proc helpersFresh(): string =
  ## "" when both guarded helpers are accepted, otherwise the refusals.
  for name in ["repro-evidence-sink", "repro-binary-cache"]:
    try: discard freshRepoBinary(RepoRoot, name)
    except StaleHelperBinary as e: result.add(e.msg & "\n")

proc rootEntries(): seq[string] =
  for kind, p in walkDir(RepoRoot, relative = true): result.add(p)

suite "a plain test compile keeps the guarded helpers fresh":
  test "nim c -r of the sink suite after just build passes, and the helpers stay accepted":
    when not defined(linux):
      skip("Linux only: the helper lists are written with strace")
    else:
      if getEnv("REPRO_RUN_PLAIN_COMPILE_TEST") != "1":
        skip("opt-in: set REPRO_RUN_PLAIN_COMPILE_TEST=1 after `just build` (it compiles the sink suite into the checkout's .nimcache)")
      else:
        let before = helpersFresh()
        checkpoint before
        require before == ""
        let hadNimcache = dirExists(RepoRoot / ".nimcache")
        if hadNimcache:
          # The control needs the root to change: start without it.
          removeDir(RepoRoot / ".nimcache")
        let entriesBefore = rootEntries()
        let (o, c) = execCmdEx(quoteShellCommand(["nim", "c", "-r", "--hints:off",
          "--warnings:off", "--out:" & RepoRoot / "build" / "test-bin" /
          "plain-compile-sink", SinkTest]), workingDir = RepoRoot)
        checkpoint o[max(0, o.len - 4000) .. ^1]
        check c == 0
        let entriesAfter = rootEntries()
        checkpoint "root entries before: " & $entriesBefore.len & ", after: " & $entriesAfter.len
        check ".nimcache" in entriesAfter
        check ".nimcache" notin entriesBefore
        let after = helpersFresh()
        checkpoint after
        check after == ""
