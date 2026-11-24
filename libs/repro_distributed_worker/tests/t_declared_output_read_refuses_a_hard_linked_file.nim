## The daemon reads a declared output only when the file is solely the
## lease's: a regular file with more than one hard link is refused.
##
## A lease that can hard-link a file the daemon can read (a file outside the
## lease, such as a key of the daemon's user) into its declared output
## directory would otherwise have the daemon open the link and ship the other
## file's bytes, although the lease itself only made a link. The check is on
## the link count of the descriptor the read uses (`fstat`), so nothing can
## swap the file between the check and the read.
##
## Real filesystem, no mocks: a real file, a real `link(2)`.
##
## Cases:
##   * a file with one link is read (positive control: the refusal is not a
##     reader that refuses everything);
##   * the same path after `link(2)` to a "secret" outside the worktree is
##     refused, with no bytes returned, and the reason names the link count;
##   * once the other link is gone the file is a plain file again and is read.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import repro_distributed_worker/receiver

when defined(posix):
  suite "a declared output with another hard link is not read":
    test "hard link to a file outside the worktree is refused":
      let base = createTempDir("hardlink-out-", "")
      defer: removeDir(base)
      let worktree = base / "lease"
      createDir(worktree / "out")
      let secret = base / "secret"
      writeFile(secret, "daemon-only bytes")

      # Positive control: an ordinary output is read.
      writeFile(worktree / "out" / "plain", "plain output")
      let plain = readDeclaredOutput(worktree, "out/plain")
      check plain.present
      check plain.ok
      check plain.bytes.len == "plain output".len

      # The lease's `ln <secret> out/ok`.
      createHardlink(secret, worktree / "out" / "ok")
      let linked = readDeclaredOutput(worktree, "out/ok")
      check linked.present
      check not linked.ok
      check linked.bytes.len == 0
      check "hard link" in linked.reason

      # The same file once its other link is gone is solely the lease's.
      removeFile(secret)
      let alone = readDeclaredOutput(worktree, "out/ok")
      check alone.ok
      check alone.bytes.len == "daemon-only bytes".len
else:
  suite "a declared output with another hard link is not read":
    test "hard link to a file outside the worktree is refused":
      skip("needs POSIX link(2) and fstat link counts; this host is not POSIX")
