## TC-8d — certificate issuance OBSERVES the working tree; it never writes the
## user's index.
##
## Issuance reuses the pre-push gate and runs ``git status`` in the attested
## repository and in every develop-mode sibling, before and after the tests.
## A plain ``git status`` refreshes the index's cached stat data and, when it
## can take the index lock, WRITES the index back (git-status(1), "Background
## refresh"; git(1) ``--no-optional-locks``). A user staging in another
## terminal while ``repro test`` runs then races that rewrite. Every git
## invocation on the issuance path must therefore run without optional locks.
##
## The test makes the stat data stale (a tracked file rewritten with the same
## bytes, a second later) in the attested repository AND in a sibling, issues
## a certificate, and requires both ``.git/index`` files to be byte-identical
## with an unchanged mtime. The positive control: a plain ``git status``
## afterwards DOES rewrite them, so the setup really invites a refresh.
##
## NO MOCKS: real repositories, the built ``repro``. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, times, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_working_tree_fixture

type IndexSnapshot = object
  bytes: string
  mtime: Time

proc snapshot(repo: string): IndexSnapshot =
  let path = repo / ".git" / "index"
  IndexSnapshot(bytes: readFile(path), mtime: getLastModificationTime(path))

proc makeStatStale(repo, file: string) =
  ## Rewrite ``file`` with its own bytes after the index was written, so its
  ## cached stat no longer matches while its content does.
  let path = repo / file
  let body = readFile(path)
  sleep(1100)
  writeFile(path, body)

suite "TC-8d — issuance leaves the user's index untouched":

  test "t_issuance_leaves_the_user_index_untouched":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupCertifyFixture("tc8d-index")
      defer: removeDir(fx.sib.scratch)
      let app = fx.sib.app
      let libB = fx.sib.ws / "lib-b"
      # A modified working tree, so the tested state is not HEAD's.
      writeFile(app / "added.txt", "a new file\n")
      discard fx.gitIn(app, "add added.txt")
      # Settle both indexes, then make their stat data stale.
      discard fx.gitIn(app, "status --porcelain")
      discard fx.gitIn(libB, "status --porcelain")
      makeStatStale(app, "README.md")
      makeStatStale(libB, "README.md")
      let appBefore = snapshot(app)
      let libBefore = snapshot(libB)
      sleep(1100)  # an index rewritten now would carry a later mtime

      let tested = fx.workingTreeContentId(app)
      let res = fx.certify(fx.writeFixtureJson("t-unit", "exit 0"))
      checkpoint(res.output)
      check res.code == 0
      check fx.issuedFor(tested).len == 1

      let appAfter = snapshot(app)
      let libAfter = snapshot(libB)
      check appAfter.bytes == appBefore.bytes
      check appAfter.mtime == appBefore.mtime
      check libAfter.bytes == libBefore.bytes
      check libAfter.mtime == libBefore.mtime

      # Positive control: the stale stat data does invite a rewrite.
      discard fx.gitIn(app, "status --porcelain")
      discard fx.gitIn(libB, "status --porcelain")
      check snapshot(app).bytes != appBefore.bytes
      check snapshot(libB).bytes != libBefore.bytes
