## Declared-Repository-Renames.md §3.3 — an UNRELATED git repository at the
## declared previous path is refused, named, not cloned over, and left exactly
## where it is.
##
## This is the case the `previously` key makes newly reachable and therefore
## newly dangerous: a forge FREES the old name when a repository is renamed and
## lets anyone create a new repository there, so "a checkout at the path this
## fragment used to declare" is not by itself evidence of anything.
##
## The companion case is `no_shared_history`: a directory whose remote DOES
## agree (someone ran `git remote set-url` by hand, or the old URL is served by
## a different repository) but whose object store shares nothing with the
## declared repo. Both are asserted here because they are the two halves of
## §3.3 and only together do they prove neither half was dropped.

import std/[json, os, strutils, unittest]
import declared_rename_fixture

suite "declared rename — an unrelated directory at the previous path":

  test "t_rename_refuses_unrelated_directory_at_previous_path":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newRenameFixture(gitBin, "unrelated")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      # An entirely unrelated repository, served under its own name.
      let stranger = fx.seedOrigin(gitBin, "stranger")

      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "stranger", oldPath)
      # The operator's own work, in the directory the tool must not touch.
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c precious")
      let strangerHead = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()
      check strangerHead == stranger.tipSha

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2

      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "previous_remote_mismatch"
      check entry.field("syncCase") == "relocation_refused"
      check "stranger" in entry.field("relocationDetail")

      # UNTOUCHED, and in particular NOT cloned over. The whole value of the
      # refusal is that the directory survives it.
      check dirExists(oldPath / ".git")
      check "precious" in localBranches(gitBin, oldPath)
      check requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip() == strangerHead
      check not dirExists(fx.workspaceRoot / "widget-pm")

  test "t_rename_refuses_a_matching_remote_with_no_shared_object":
    ## §3.3(b). The remote agrees — the directory really does carry the
    ## declared previous URL — but its object store shares nothing with the
    ## repository now published at the new URL. The verdict names both tips it
    ## probed and how many objects it sampled, so it is auditable rather than
    ## asserted.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = newRenameFixture(gitBin, "noshared")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm")
      # A repository served at the OLD url that is not the renamed one: the
      # old name was freed and somebody else created a repository there, which
      # is precisely the hazard §2.3 rule 2 and this refusal guard against.
      discard fx.seedOrigin(gitBin, "widget-specs")

      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-specs", oldPath)
      let impostorHead = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2

      let entry = fx.readReport().entryFor("widget-pm")
      check entry.field("relocation") == "no_shared_history"
      check entry.field("syncCase") == "relocation_refused"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check "sampled blob" in detail
      check impostorHead in detail

      check dirExists(oldPath / ".git")
      check not dirExists(fx.workspaceRoot / "widget-pm")
