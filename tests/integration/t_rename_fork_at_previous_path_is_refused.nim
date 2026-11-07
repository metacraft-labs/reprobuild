## Declared-Repository-Renames.md §3.3(a) — a FORK at the previous path is
## refused, and the point of the case is WHICH half of the identity check
## refuses it.
##
## A fork shares every object with its upstream, so the history half of the
## check — `merge-base`, and equally the blob-presence fallback — accepts it
## unconditionally. Only the REMOTE half can tell them apart, because a fork
## sits under a different org and its URL matches neither the current URL nor
## any URL derived from a declared prior identity.
##
## So this test asserts the refusal AND the premise that makes it load-bearing:
## that the history half really would have said yes. A test that only checked
## "it was refused" would pass against an implementation that refused forks for
## some unrelated reason.
##
## Asserted:
##   1. `relocation=previous_remote_mismatch`, naming the URL found and the
##      URLs accepted.
##   2. Exit 2, and the directory is UNTOUCHED — not moved, not deleted.
##   3. NOT cloned over: "cloning fresh at the new path after the tool has
##      concluded something is wrong reproduces the exact
##      orphan-beside-empty-clone outcome the mechanism exists to prevent".
##   4. The premise: the fork and the declared repo share commits, so a
##      history-only check accepts it.

import repro_test_support/reasoned_skip
import std/[json, os, strutils, unittest]
import declared_rename_fixture

suite "declared rename — a fork at the previous path":

  test "t_rename_fork_at_previous_path_is_refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "fork")
      defer: removeDir(fx.scratch)

      let seeded = fx.seedOrigin(gitBin, "widget-pm")
      # The fork: a second bare at a DIFFERENT server-side path, cloned from
      # the same upstream, so it shares every object with it. `origins/` is the
      # prefix root, so a different name here is a different org/path in URL
      # terms — exactly the discriminator a real fork has.
      discard requireGit(q(gitBin) & " clone --bare " &
        q(fx.originsDir / "widget-pm") & " " &
        q(fx.originsDir / "someone-elses-fork"))

      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      # What sits at the declared previous path is a checkout OF THE FORK.
      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "someone-elses-fork", oldPath)
      let forkHead = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      # 4. THE PREMISE. The fork shares the upstream's history, so the history
      #    half of the identity check would accept it: the commit is literally
      #    the same object id.
      check forkHead == seeded.tipSha
      check run(q(gitBin) & " -C " & q(oldPath) & " cat-file -e " &
        q(seeded.tipSha)).code == 0

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)

      # 1 + 2.
      check res.code == 2
      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "previous_remote_mismatch"
      check entry.field("syncCase") == "relocation_refused"
      check entry.field("executionStatus") == "refused"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "someone-elses-fork" in detail      # the URL found
      check "widget-pm" in detail               # the URLs accepted
      check "widget-specs" in detail            # the directory named

      # 2. The directory is exactly where it was, with its remote intact.
      check dirExists(oldPath / ".git")
      check requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip() == forkHead
      check requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote get-url origin").strip() ==
        fx.originUrl("someone-elses-fork")

      # 3. And NOTHING was cloned at the declared path.
      check not dirExists(fx.workspaceRoot / "widget-pm")
      check entry.field("action") == "none"
