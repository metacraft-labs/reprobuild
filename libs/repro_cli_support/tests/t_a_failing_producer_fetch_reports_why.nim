## A lock-pinned producer fetch that fails says WHY.
##
## ``fetchLockPinnedProducer`` materializes a cross-repo producer at its
## pinned revision with ``git fetch``. When both of its fetch attempts fail
## (by revision, then every branch and tag), the error it raises is the only
## diagnosis a CI log carries. It must quote git's own reason. It did not:
## git was run without ``poStdErrToStdOut``, git reports a failed fetch only
## on stderr, and the error ended in an empty string:
##
##     cross-repo producer "p" fetch failed from <url> at pinned revision
##     <rev>:
##
## Properties asserted, each separately falsifiable:
##
##   1. the error carries git's reason for the failure;
##   2. it carries the reason of BOTH attempts (the by-revision fetch is the
##      one expected to work, so its reason is usually the explanation);
##   3. no partially materialized checkout is left behind.
##
## The remote is a ``file://`` URL to a directory that does not exist, so
## git's reason is deterministic and needs no network.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The production ``fetchLockPinnedProducer`` runs the real ``git`` against a
## real (missing) local remote in a real temporary workspace.

import std/[os, strutils, unittest]

import repro_cli_support
import repro_lock
import repro_test_support/reasoned_skip

const
  ProducerName = "missing-producer"
  PinnedRevision = "0123456789abcdef0123456789abcdef01234567"
  # git's wording for a remote path that is not a repository. Both fetch
  # attempts hit the same remote, so both report it.
  GitReason = "does not appear to be a git repository"

suite "a failing lock-pinned producer fetch reports git's reason":
  test "both fetch attempts' reasons reach the error":
    if findExe("git").len == 0:
      skip("git is not on PATH, and fetchLockPinnedProducer runs the real git")
    else:
      let scratch = getTempDir() / ("t_failing_producer_fetch_" & $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)
      let workspace = scratch / "consumer"
      createDir(workspace)
      let missingRemote = scratch / "no-such-remote.git"
      let dep = LockedDep(
        name: ProducerName,
        coordinates: Coordinates(kind: ckVcs,
          url: "file://" & missingRemote, revision: PinnedRevision),
        integrity: "git-sha1:" & PinnedRevision)

      var message = ""
      try:
        discard fetchLockPinnedProducer(dep, workspace)
      except OSError as e:
        message = e.msg
      checkpoint("error: " & message)

      check message.len > 0
      check ("fetch failed from file://" & missingRemote) in message
      # (1) git's reason is there at all.
      check GitReason in message
      # (2) and for both attempts.
      check message.count(GitReason) >= 2
      # (3) nothing that looks materialized is left behind.
      check not dirExists(workspace / ".repro" / "cross-repo-producers" /
        ProducerName / PinnedRevision)
