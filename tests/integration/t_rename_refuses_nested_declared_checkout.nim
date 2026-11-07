## Declared-Repository-Renames.md §4 `nested_checkout_inside_candidate` — a
## declared repo checked out INSIDE the candidate refuses the move.
##
## THIS IS A LIVE CASE IN THIS WORKSPACE, not a hypothetical. The nested
## topology is supported and used: the reference trees sit at paths like
## `reprobuild/references/llvm-project`, inside another declared checkout. A
## move of an outer path would relocate a dozen inner repos as a side effect,
## leaving every one of them at a path no fragment declares — manufacturing, in
## bulk, exactly the orphan this mechanism exists to eliminate.
##
## So the refusal is not over-caution. It is the one case where performing the
## operation would create MORE orphans than it resolves.
##
## Asserted:
##   1. `relocation=nested_checkout_inside_candidate`, naming the inner repo
##      and the fragment that declares it.
##   2. Exit 2, nothing moved, the inner checkout untouched and still at its
##      declared path.
##   3. NOT cloned over at the outer declared path.
##   4. The inner repo itself still syncs — per-repo atomicity: one repo
##      awaiting a decision must not block the other hundred.

import repro_test_support/reasoned_skip
import std/[json, os, strutils, unittest]
import declared_rename_fixture

suite "declared rename — a declared checkout nested inside the candidate":

  test "t_rename_refuses_nested_declared_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "nested")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "outer-pm")
      discard fx.seedOrigin(gitBin, "inner-ref")

      # The outer repo is being renamed `outer-specs` -> `outer-pm`. The inner
      # repo is declared at a path UNDERNEATH the outer repo's OLD tree, which
      # is where it actually sits on disk — the reference-tree topology.
      fx.writeFragment("outer-pm", "outer-pm", "outer-pm",
        previously = "[{ name = \"outer-specs\", path = \"outer-specs\" }]")
      fx.writeFragment("inner-ref", "inner-ref",
        "outer-specs/references/inner-ref")
      fx.writeProject(["outer-pm", "inner-ref"])

      let outerOld = fx.workspaceRoot / "outer-specs"
      fx.cloneInto(gitBin, "outer-pm", outerOld)
      discard requireGit(q(gitBin) & " -C " & q(outerOld) &
        " remote set-url origin " & q(fx.originUrl("outer-specs")))
      let innerPath = outerOld / "references" / "inner-ref"
      createDir(outerOld / "references")
      fx.cloneInto(gitBin, "inner-ref", innerPath)
      discard requireGit(q(gitBin) & " -C " & q(innerPath) &
        " switch -c work-only-here")
      let innerHead = requireGit(q(gitBin) & " -C " & q(innerPath) &
        " rev-parse HEAD").strip()

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      check res.code == 2

      let report = fx.readReport()
      let entry = report.entryFor("outer-pm")
      check entry.field("relocation") ==
        "nested_checkout_inside_candidate"
      check entry.field("syncCase") == "relocation_refused"
      check entry.field("executionStatus") == "refused"
      let detail = entry.field("relocationDetail")
      checkpoint("detail: " & detail)
      # 1. The inner repo and its fragment are NAMED. A refusal that only said
      #    "something is nested" would leave the operator to find a dozen of
      #    them by hand.
      check "outer-specs/references/inner-ref" in detail
      check "inner-ref" in detail
      check "inner-ref.toml" in detail

      # 2 + 3. Nothing moved, nothing cloned over, the inner work intact.
      check dirExists(outerOld / ".git")
      check dirExists(innerPath / ".git")
      check not dirExists(fx.workspaceRoot / "outer-pm")
      check "work-only-here" in localBranches(gitBin, innerPath)
      check requireGit(q(gitBin) & " -C " & q(innerPath) &
        " rev-parse HEAD").strip() == innerHead

      # 4. Per-repo atomicity: the inner repo was still reconciled.
      let innerEntry = report.entryFor("outer-specs/references/inner-ref")
      check innerEntry.field("relocation") == ""
      check innerEntry.field("executionStatus") != "refused"

  test "t_rename_relocates_when_the_nested_repo_is_declared_but_absent":
    ## The refusal is about what moving would DRAG, so it is conditioned on the
    ## inner tree EXISTING. A declared-but-unmaterialised inner repo drags
    ## nothing, and refusing on the declaration alone would make the key inert
    ## for every repo that happens to have a nested member declared.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let fx = newRenameFixture(gitBin, "nestedabsent")
      defer: removeDir(fx.scratch)

      discard fx.seedOrigin(gitBin, "outer-pm")
      discard fx.seedOrigin(gitBin, "inner-ref")
      fx.writeFragment("outer-pm", "outer-pm", "outer-pm",
        previously = "[{ name = \"outer-specs\", path = \"outer-specs\" }]")
      # Declared under the NEW tree (where it will live after the rename) and
      # not checked out anywhere yet.
      fx.writeFragment("inner-ref", "inner-ref",
        "outer-pm/references/inner-ref")
      fx.writeProject(["outer-pm", "inner-ref"])

      let outerOld = fx.workspaceRoot / "outer-specs"
      fx.cloneInto(gitBin, "outer-pm", outerOld)
      discard requireGit(q(gitBin) & " -C " & q(outerOld) &
        " remote set-url origin " & q(fx.originUrl("outer-specs")))

      let res = fx.invokeSync()
      checkpoint("sync output:\n" & res.output)
      let entry = fx.readReport().entryFor("outer-pm")
      check entry.field("relocation") == "relocated"
      check dirExists(fx.workspaceRoot / "outer-pm" / ".git")
      check not dirExists(outerOld)
      # And the inner repo was cloned into its declared place under the NEW
      # tree, which is only reachable because the outer move happened first.
      check dirExists(fx.workspaceRoot / "outer-pm" / "references" /
        "inner-ref" / ".git")
