## Recovery classifications must never advise stashing upstream content.
import std/[os, strutils, unittest]
import repro_workspace_manifests/[resolver, sync_planner]

suite "interrupted fast-forward planning":
  test "ordinary sync refuses with the exact target recovery command":
    let repo = ResolvedRepo(name: "lib", path: "lib", branch: "main")
    var obs = RepoSyncObservation(exists: true, isClean: false,
      headSha: "1111111", currentBranch: "main", remoteBranchTip: "2222222")
    obs.interruptedFastForwardTarget = "2222222"
    let decision = classifyRepoState(repo, obs)
    check syncCaseTag(decision.syncCase) == "interrupted_fast_forward"
    check decision.action == saNone
    check "git -C lib reset --hard 2222222" in decision.refusalReason
    check "stash" notin decision.refusalReason

  test "role sync refuses compatible partial upstream content before fast-forward":
    let repo = ResolvedRepo(name: "lib", path: "lib", branch: "main")
    var obs = MainlineSyncObservation(exists: true, isClean: false,
      currentBranch: "main", headSha: "1111111", roleBranch: "agents",
      roleTip: "2222222", headInRole: true)
    obs.interruptedFastForwardTarget = "2222222"
    let decision = classifyMainlineSync(repo, obs, msfFastForwardOnly)
    check mainlineSyncCaseTag(decision.syncCase) == "interrupted_fast_forward"
    check decision.action == msaNone
    check "git -C lib reset --hard 2222222" in decision.refusalReason
    check "stash" notin decision.refusalReason

  test "ordinary local dirt on a fast-forwardable role target remains untouched":
    let repo = ResolvedRepo(name: "lib", path: "lib", branch: "main")
    let obs = MainlineSyncObservation(exists: true, isClean: false,
      currentBranch: "main", headSha: "1111111", roleBranch: "agents",
      roleTip: "2222222", headInRole: true)
    let decision = classifyMainlineSync(repo, obs, msfFastForwardOnly)
    check mainlineSyncCaseTag(decision.syncCase) == "dirty"
    check decision.action == msaNone

  test "ordinary local work keeps the dirty refusal":
    let repo = ResolvedRepo(name: "lib", path: "lib", branch: "main")
    let obs = RepoSyncObservation(exists: true, isClean: false,
      headSha: "1111111", currentBranch: "main", remoteBranchTip: "2222222")
    let decision = classifyRepoState(repo, obs)
    check syncCaseTag(decision.syncCase) == "dirty"
    check "stash" in decision.refusalReason

  test "recovery commands quote checkout paths containing shell syntax":
    let path = "lib with 'quotes';$(printf unsafe)"
    let repo = ResolvedRepo(name: "lib", path: path, branch: "main")
    let obs = RepoSyncObservation(exists: true, isClean: false,
      interruptedFastForwardTarget: "2222222")
    let decision = classifyRepoState(repo, obs)
    check "git -C " & quoteShell(path) & " reset --hard 2222222" in decision.refusalReason
