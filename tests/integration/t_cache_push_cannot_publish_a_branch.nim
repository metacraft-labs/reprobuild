## The eager post-commit cache push writes the cache namespace, or nothing.
##
## Unified-Locking-And-Hooks.md §7.2 gives the post-commit push exactly one
## destination: ``refs/cache/<workspace>/<branch>`` in the shared bare that
## sibling checkouts read through alternates. It is an object-propagation
## mechanism for one machine. Nothing in it is a publication.
##
## That distinction is what licenses the two properties the push is built on:
## it runs ``--force``, and it runs ``--no-verify``, detached, with its result
## discarded. Both are correct for a private object store and both are
## indefensible against a shared remote — a background process that force-pushes
## unreviewed work past every gate, silently, is the worst version of this
## component. So "it only ever writes the cache namespace" is not an
## implementation detail to be preserved by care; it is the premise the rest of
## the design rests on, and this test is where it is held.
##
## What is asserted, and why each would fail if the premise broke:
##
##   1. A REAL push happens and lands in the cache namespace. The commit's
##      object is unreachable from the sibling checkout before the push and
##      readable after it, through the shared bare alone — so the positive
##      case cannot be satisfied by a push that does nothing. The branch here
##      carries a '/', because a plain single-word branch would not exercise
##      the multi-component ref assembly at all.
##   2. The same push moves NOTHING on the upstream. The upstream bare's refs
##      are captured before and after and must be identical. This is the
##      failure that motivated the test: a branch appearing on a remote that
##      nobody pushed to.
##   3. The shared bare's own ``refs/heads/*`` are equally untouched. The cache
##      namespace is a namespace, not a naming convention.
##   4. The argument vector is inspected directly. ``cacheRefPushArgvFault``
##      is given hand-built commands that push a branch ref, that push to a
##      remote alias, and that omit the refspec, and must reject each — these
##      are the shapes a plausible future edit produces.
##   5. Refusal is a refusal. A hostile workspace name is rejected AND leaves
##      the bare byte-identical in its refs, so "refused" cannot quietly mean
##      "pushed somewhere else".
##
## Hermetic: local bare repositories under one ``createTempDir``; no network.
## Skipped only when ``git`` is absent.

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, unittest]

import shared_clones

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string): string =
  let res = runCmd(command)
  if res.code != 0:
    # Written straight out, not via ``checkpoint``: a checkpoint is only
    # flushed by a failing ``check``, and a fixture that could not be built
    # never reaches one.
    echo "fixture command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output
    quit 1
  res.output

proc refSnapshot(gitBin, repoPath: string): seq[string] =
  ## Every ref in ``repoPath`` as "<sha> <name>", sorted. Comparing whole
  ## snapshots (rather than probing for one expected name) is what makes the
  ## "nothing moved" assertions catch a push that landed somewhere nobody
  ## thought to look for.
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " for-each-ref --format=" & q("%(objectname) %(refname)")).splitLines()
      .mapIt(it.strip()).filterIt(it.len > 0)
  result.sort()

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"cache-push tester\"")

suite "the cache push cannot publish a branch":

  test "test_cache_push_writes_only_the_cache_namespace":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-cache-push-guard-", "")
      defer: removeDir(scratch)

      # ---- fixture: upstream, shared bare, two sibling checkouts ----------
      let upstream = scratch / "upstream.git"
      let seed = scratch / "seed"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(upstream))
      discard requireGit(q(gitBin) & " init -b main " & q(seed))
      configIdentity(gitBin, seed)
      writeFile(seed / "README.md", "guard fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m base")
      discard requireGit(q(gitBin) & " -C " & q(seed) & " push " &
        q(upstream) & " main")

      let bare = scratch / "shared.git"
      discard requireGit(q(gitBin) & " clone --bare " & q(upstream) & " " &
        q(bare))

      let w1 = scratch / "w1"
      let w2 = scratch / "w2"
      discard requireGit(q(gitBin) & " clone " & q(upstream) & " " & q(w1))
      discard requireGit(q(gitBin) & " clone " & q(upstream) & " " & q(w2))
      configIdentity(gitBin, w1)
      configIdentity(gitBin, w2)
      check wireAlternates(w1, bare).ok
      check wireAlternates(w2, bare).ok

      # A branch shaped like the ones this repository actually uses: the '/'
      # is the part a single-component fixture would never exercise.
      let branch = "fix/leak-check"
      discard requireGit(q(gitBin) & " -C " & q(w1) & " switch -c " & branch)
      writeFile(w1 / "feature.txt", "work that must not be published\n")
      discard requireGit(q(gitBin) & " -C " & q(w1) & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(w1) & " commit -m \"w1 work\"")
      let newSha = requireGit(q(gitBin) & " -C " & q(w1) &
        " rev-parse HEAD").strip()

      let upstreamBefore = refSnapshot(gitBin, upstream)
      let bareBefore = refSnapshot(gitBin, bare)

      # Falsifiability of the positive case: the object is NOT reachable from
      # the sibling checkout yet, so an assertion that it is afterwards can
      # only be satisfied by a push that really moved objects.
      check runCmd(q(gitBin) & " -C " & q(w2) & " cat-file -e " & newSha).code != 0

      # ---- (1) the real push, and it must reach the cache namespace -------
      let pushed = pushCacheRef(gitBin, w1, bare, "W1")
      if not pushed.ok:
        checkpoint("pushCacheRef diagnostic: " & pushed.diagnostic)
      check pushed.ok
      # Read non-fatally: when this ref is missing the interesting question is
      # where the objects went INSTEAD, and the assertions below answer it.
      let cacheRefSha = runCmd(q(gitBin) & " -C " & q(bare) &
        " rev-parse --verify --quiet refs/cache/W1/" & branch)
      check cacheRefSha.output.strip() == newSha
      let afterPush = runCmd(q(gitBin) & " -C " & q(w2) & " cat-file -e " & newSha)
      if afterPush.code != 0:
        checkpoint("w2 cat-file after push: " & afterPush.output)
      check afterPush.code == 0

      # ---- (2) the upstream saw none of it --------------------------------
      let upstreamAfter = refSnapshot(gitBin, upstream)
      if upstreamAfter != upstreamBefore:
        checkpoint("upstream refs changed:\n  before: " &
          upstreamBefore.join("\n          ") & "\n  after:  " &
          upstreamAfter.join("\n          "))
      check upstreamAfter == upstreamBefore
      check not upstreamAfter.anyIt(it.contains(branch))

      # ---- (3) and neither did the shared bare's branches -----------------
      let bareHeadsAfter = refSnapshot(gitBin, bare).filterIt(
        it.contains(" refs/heads/"))
      check bareHeadsAfter == bareBefore.filterIt(it.contains(" refs/heads/"))
      for entry in refSnapshot(gitBin, bare):
        let name = entry.split(' ')[^1]
        if name.contains(branch):
          check name.startsWith(cacheRefNamespace)

      # ---- (4) the guard reads the command, not the intention -------------
      let plan = cacheRefPushPlan(bare, "W1", branch)
      check plan.ok
      check plan.cacheRef == "refs/cache/W1/" & branch
      let goodArgv = cacheRefPushArgv(w1, plan)
      check cacheRefPushArgvFault(goodArgv, bare) == ""
      check goodArgv[^1] == "HEAD:refs/cache/W1/" & branch

      # Each of these is a command a future edit could plausibly produce.
      # None may be judged acceptable.
      let branchRefArgv = @["-C", w1, "push", "--force", "--no-verify", bare,
        "HEAD:refs/heads/" & branch]
      check cacheRefPushArgvFault(branchRefArgv, bare).len > 0
      let remoteAliasArgv = @["-C", w1, "push", "--force", "--no-verify",
        "origin", "HEAD:refs/cache/W1/" & branch]
      check cacheRefPushArgvFault(remoteAliasArgv, bare).len > 0
      let noRefspecArgv = @["-C", w1, "push", "--force", "--no-verify", bare]
      check cacheRefPushArgvFault(noRefspecArgv, bare).len > 0
      let noDestinationArgv = @["-C", w1, "push", "--force", "--no-verify"]
      check cacheRefPushArgvFault(noDestinationArgv, bare).len > 0
      let escapingArgv = @["-C", w1, "push", "--force", "--no-verify", bare,
        "HEAD:refs/cache/../heads/" & branch]
      check cacheRefPushArgvFault(escapingArgv, bare).len > 0

      # ---- (5) a refused push is a push that did not happen ---------------
      # Destinations that are not a shared bare on this filesystem. A remote
      # alias and a URL are the two ways this component could have reached a
      # real remote, so both are named explicitly.
      check not cacheRefPushPlan("origin", "W1", branch).ok
      check not cacheRefPushPlan("https://example.invalid/r.git", "W1",
        branch).ok
      check not cacheRefPushPlan("git@example.invalid:org/r.git", "W1",
        branch).ok
      check not cacheRefPushPlan(bare.extractFilename, "W1", branch).ok
      # Names that could reposition the ref out of its namespace.
      check not cacheRefPushPlan(bare, "..", branch).ok
      check not cacheRefPushPlan(bare, "a/b", branch).ok
      check not cacheRefPushPlan(bare, "", branch).ok
      check not cacheRefPushPlan(bare, "W1", "refs/heads/" & branch).ok
      check not cacheRefPushPlan(bare, "W1", "fix/../../heads/x").ok
      check not cacheRefPushPlan(bare, "W1", "").ok

      let refsBeforeRefusal = refSnapshot(gitBin, bare)
      let refused = pushCacheRef(gitBin, w1, bare, "..")
      check not refused.ok
      check refSnapshot(gitBin, bare) == refsBeforeRefusal
      check refSnapshot(gitBin, upstream) == upstreamBefore
