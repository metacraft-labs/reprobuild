## Declared-Repository-Renames.md §3.3 — the identity check that authorises
## MOVING a directory must not pass on blobs that unrelated repositories share
## by coincidence.
##
## Blob ids are content hashes, so any two repositories that both carry an
## empty file (`__init__.py`, `.gitkeep`), a stock LICENSE text or a template
## `.gitignore` share those blob ids without sharing any history. Before this
## was fixed, the object-presence half of the check accepted a candidate when
## ANY ONE sampled blob was present, and the remote half accepted a candidate
## with NO remotes at all, so an unrelated, never-published repository at a
## declared previous path was moved into the declared path on the strength of
## an empty file. The three cases below each recreate one way that happened:
##
##   1. no remotes + common blobs only        -> refused, remote half;
##   2. matching remote + common blobs only   -> refused, object half;
##   3. matching remote + ONE distinctive blob of several -> refused, quorum.
##
## Each case asserts the directory is untouched and nothing was cloned over it,
## which is the property that matters to the operator.
##
## The positive controls: a genuine renamed AND rewritten repository, whose
## commits are all different but whose blobs are the same, still relocates on
## the object-presence fallback (`t_rename_renamed_and_rewritten_repo_relocates`,
## a one-blob sample), and still relocates when it holds only a quorum of a
## larger sample (case 4 below, four of seven).
##
## NO MOCKS: see `declared_rename_fixture.nim` for why this mechanism is only
## meaningful against real git object stores and the real `repro` binary.

import repro_test_support/reasoned_skip
import std/[os, strutils, unittest]
import declared_rename_fixture

const
  # The MIT licence text as GitHub's licence picker emits it, minus the
  # copyright line. Byte-identical copies of this blob exist in a very large
  # number of unrelated repositories.
  stockLicense = """MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
  templateGitignore = "# Byte-compiled / optimized / DLL files\n" &
    "__pycache__/\n*.py[cod]\n*$py.class\n\n# Distribution / packaging\n" &
    "build/\ndist/\n*.egg-info/\n"

proc commonFiles(): seq[tuple[path, content: string]] =
  ## Files whose bytes coincide across unrelated repositories: the empty blob
  ## (twice, at two paths, so a sampler that counted paths rather than distinct
  ## blobs would count it twice), a stock licence and a template `.gitignore`.
  @[(path: "pkg/__init__.py", content: ""),
    (path: "pkg/sub/.gitkeep", content: ""),
    (path: "LICENSE", content: stockLicense),
    (path: ".gitignore", content: templateGitignore)]

proc distinctiveFiles(owner: string; count: int):
    seq[tuple[path, content: string]] =
  for i in 0 ..< count:
    result.add((path: "lib/module" & $i & ".nim",
      content: "# module " & $i & " of " & owner &
        "\nproc entry" & $i & "*(): int = " & $(i * 7919) & "\n"))

proc assertUntouched(fx: RenameFixture; gitBin, oldPath, head: string) =
  check dirExists(oldPath / ".git")
  check requireGit(q(gitBin) & " -C " & q(oldPath) &
    " rev-parse HEAD").strip() == head
  check "precious" in localBranches(gitBin, oldPath)
  check not dirExists(fx.workspaceRoot / "widget-pm")

suite "declared rename — identity is not established by coincident blobs":

  test "t_rename_refuses_remoteless_repo_sharing_only_common_blobs":
    ## Case 1. An unrelated repository that was never published (no remote)
    ## sits at the declared previous path and carries an empty `__init__.py`,
    ## the stock MIT licence and a template `.gitignore`, all of which the
    ## declared repository also carries. Nothing about it says it is
    ## `widget-pm`: with no remote there is no URL to agree, and the fork
    ## defence of §3.3(a) never runs. It must be refused on the remote half.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "remoteless")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm", extraFiles = commonFiles())
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      # The operator's own, unrelated project. `git init`, never pushed.
      let oldPath = fx.workspaceRoot / "widget-specs"
      discard requireGit(q(gitBin) & " init -b main " & q(oldPath))
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " config user.name \"Rename Tester\"")
      for (relPath, content) in commonFiles() & distinctiveFiles("mine", 3):
        createDir((oldPath / relPath).parentDir)
        writeFile(oldPath / relPath, content)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " commit -m \"my own project\"")
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c precious")
      check requireGit(q(gitBin) & " -C " & q(oldPath) & " remote").strip() ==
        ""
      let head = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)

      let entry = fx.readReport().entryFor("widget-pm")
      checkpoint("detail: " & entry.field("relocationDetail"))
      check entry.field("relocation") == "previous_remote_mismatch"
      check entry.field("syncCase") == "relocation_refused"
      check "no remote" in entry.field("relocationDetail")
      check res.code == 2
      fx.assertUntouched(gitBin, oldPath, head)

  test "t_rename_refuses_matching_remote_sharing_only_common_blobs":
    ## Case 2. The old name was freed by the forge and somebody created a new,
    ## unrelated repository there; the checkout at the previous path is a
    ## clone of THAT, so its remote really is the declared previous URL. It
    ## shares the empty blob, the licence and the `.gitignore` with the
    ## renamed repository and nothing else. Those blobs are not evidence of
    ## lineage, so the object half must find none and refuse.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "commonblobs")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "widget-pm", extraFiles = commonFiles())
      discard fx.seedOrigin(gitBin, "widget-specs",
        extraFiles = commonFiles() & distinctiveFiles("impostor", 3))
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-specs", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c precious")
      let head = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()
      # Premise: the impostor really does hold the common blobs.
      check requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD:LICENSE").strip().len > 0

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)

      let entry = fx.readReport().entryFor("widget-pm")
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check entry.field("relocation") == "no_shared_history"
      check entry.field("syncCase") == "relocation_refused"
      check "sampled blob" in detail
      check res.code == 2
      fx.assertUntouched(gitBin, oldPath, head)

  test "t_rename_refuses_matching_remote_sharing_one_distinctive_blob":
    ## Case 3. As case 2, but the impostor also carries ONE byte-identical
    ## copy of a distinctive file of the renamed repository (a vendored file,
    ## say) out of the renamed repository's six. One coincident file is not
    ## lineage: the check requires a quorum of the sampled distinctive blobs.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "oneblob")
      defer: removeDir(fx.scratch)

      let ours = distinctiveFiles("widget-pm", 6)
      discard fx.seedOrigin(gitBin, "widget-pm",
        extraFiles = commonFiles() & ours)
      discard fx.seedOrigin(gitBin, "widget-specs",
        extraFiles = commonFiles() & distinctiveFiles("impostor", 3) &
          @[(path: "vendor/borrowed.nim", content: ours[2].content)])
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-specs", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " switch -c precious")
      let head = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)

      let entry = fx.readReport().entryFor("widget-pm")
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      check entry.field("relocation") == "no_shared_history"
      check entry.field("syncCase") == "relocation_refused"
      check res.code == 2
      fx.assertUntouched(gitBin, oldPath, head)

suite "declared rename — a quorum of distinctive blobs still relocates":

  test "t_rename_rewritten_repo_relocates_on_a_quorum_of_distinctive_blobs":
    ## Positive control for the quorum. The genuine repository was renamed
    ## AND rewritten, and the new tip also changed three of its seven
    ## distinctive files since the checkout last fetched, so the candidate
    ## holds only four of the seven sampled blobs (plus the common ones,
    ## which do not count). Four is at least the quorum of three, so it is
    ## relocated on object presence. A fractional threshold, or a check that
    ## demanded the whole sample, would refuse exactly this long-neglected
    ## checkout. `t_rename_renamed_and_rewritten_repo_relocates` covers the
    ## same path with a one-blob sample, where the quorum is capped at one.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "quorum")
      defer: removeDir(fx.scratch)

      let seeded = fx.seedOrigin(gitBin, "widget-pm",
        extraFiles = commonFiles() & distinctiveFiles("widget-pm", 6))
      fx.writeFragment("widget-pm", "widget-pm", "widget-pm",
        previously = "[{ name = \"widget-specs\", path = \"widget-specs\" }]")
      fx.writeProject(["widget-pm"])

      let oldPath = fx.workspaceRoot / "widget-specs"
      fx.cloneInto(gitBin, "widget-pm", oldPath)
      discard requireGit(q(gitBin) & " -C " & q(oldPath) &
        " remote set-url origin " & q(fx.originUrl("widget-specs")))
      let checkoutHead = requireGit(q(gitBin) & " -C " & q(oldPath) &
        " rev-parse HEAD").strip()

      # The remote moves on: three distinctive files change, then the whole
      # history is rewritten, so the new tip shares no commit with the
      # checkout and only four of its seven distinctive blobs.
      for i in 0 ..< 3:
        writeFile(seeded.seedPath / "lib" / ("module" & $i & ".nim"),
          "# module " & $i & " of widget-pm, revised after the checkout " &
            "last fetched\n")
      let rewrittenTip = fx.rewriteOriginHistory(gitBin, "widget-pm",
        seeded.seedPath)
      check rewrittenTip != checkoutHead
      let changedBlob = requireGit(q(gitBin) & " -C " &
        q(fx.originsDir / "widget-pm") & " rev-parse " &
        q(rewrittenTip & ":lib/module0.nim")).strip()
      # Premise: the candidate really lacks the changed blobs.
      check run(q(gitBin) & " -C " & q(oldPath) & " cat-file -e " &
        q(changedBlob)).code != 0

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let entry = fx.readReport().entryFor("widget-pm")
      let evidence = entry.field("relocationEvidence")
      checkpoint("evidence: " & evidence)
      check entry.field("relocation") == "relocated"
      check entry.field("relocatedFrom") == "widget-specs"
      check "4/7 sampled blob" in evidence
      check "3 required" in evidence
      check "merge-base" notin evidence
      check dirExists(fx.workspaceRoot / "widget-pm" / ".git")
      check not dirExists(oldPath)
