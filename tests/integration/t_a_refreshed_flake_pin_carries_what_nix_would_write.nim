## NF-2 — **a refreshed `flake.lock` node carries the `narHash`,
## `lastModified` and `revCount` nix itself would write for the new revision,
## and the commit hook SAYS that it moved the pin.**
##
## Issue: reprobuild-pm `issues/2026-09-27-pre-commit-hook-repins-flake-lock-
## at-a-sibling-head-and-drops-narhash.md`. Two defects, observed in a real
## commit (`io-mon-src` re-pinned by a commit that staged two test files):
##
##   1. the moved node LOST `narHash` and `lastModified`. A `rev`-only node
##      still resolves, but the lock no longer records the content hash that
##      makes the fetch verifiable, and it is not what `nix flake update`
##      writes for the same revision;
##   2. the hook announced its refusals loudly and its ACTION silently — the
##      re-pin reached the commit without a word on the terminal.
##
## ## Why the fields can be recomputed now
##
## The refresh used to delete them because recomputing needs nix to FETCH the
## revision, and the fetch fails for a sibling revision that exists only in a
## local checkout. NF-2 no longer records such a revision at all
## (`flakeRowIsRecordable`, `t_an_unpushed_sibling_revision_is_not_recorded`),
## so every revision it records is published, and fetchable by construction.
##
## ## What is asserted
##
##   1. the commit carries the moved `alpha-src` node WITH `narHash`,
##      `lastModified` and `revCount`;
##   2. those three values EQUAL what `nix flake lock` writes for the same
##      revision, computed independently: a throwaway flake in its own
##      directory floating on the same origin's `main`, locked by nix. That is
##      a different code path from the refresh's (`builtins.fetchTree` over the
##      node's attributes), so agreement is evidence rather than an echo;
##   3. the moved `locked` object has exactly the members, in exactly the
##      order, nix writes (nix's lock writer sorts keys), so a later
##      `nix flake lock` has nothing to rewrite;
##   4. the nodes that did not move are byte-identical;
##   5. the commit's stderr names the input, the old and new revisions, the
##      sibling checkout the revision came from, that `flake.lock` was staged
##      into this commit, and the one-commit opt-out
##      (`REPRO_SKIP_LOCK_REFRESH`).
##
## ## Mutation
##
## Revert the refresh to deleting the derived fields ⇒ (1)–(3) RED. Remove the
## hook-site announcement ⇒ (5) RED (the pre-fix binary prints nothing about
## the move on stderr, only into `pre-commit-lock.log`).
##
## Test-double policy: NO mocks, doubles or fakes. Real git origins, a real
## `git commit` firing a real hook, the real `./build/bin/repro`, and real nix.
## See `nf2_flake_lock_fixture.nim` for the inventory. The case needs nix (the
## refresh cannot record a pin without it, and the independent value comes
## from it) and SKIPS LOUDLY when nix is absent.

import std/[algorithm, json, os, strutils, unittest]

import nf2_flake_lock_fixture
import repro_test_support/reasoned_skip

const caseName = "t_a_refreshed_flake_pin_carries_what_nix_would_write"

proc shown(node: JsonNode): string =
  if node.isNil: "<absent>" else: $node

proc nixLockedNodeFor(fx: Nf2Fixture; nixBin, repo: string): JsonNode =
  ## What `nix flake lock` itself writes for `<repo>`'s origin as it stands
  ## now, in a flake of its own that this test never hands to the refresh.
  let dir = fx.scratch / ("independent-" & repo)
  createDir(dir)
  writeFile(dir / "flake.nix",
    "{\n  inputs.src.url = \"git+" & originUrl(fx, repo) & "?ref=main\";\n" &
    "  outputs = _: { };\n}\n")
  discard requireCmd(q(fx.gitBin) & " init -q " & q(dir))
  discard requireCmd(q(fx.gitBin) & " -C " & q(dir) & " add -A")
  let locked = run(q(nixBin) &
    " --extra-experimental-features 'nix-command flakes' flake lock " &
    "--offline 2>&1", cwd = dir)
  if locked.code != 0 or not fileExists(dir / "flake.lock"):
    checkpoint("independent `nix flake lock` failed:\n" & locked.output)
    return nil
  parseJson(readFile(dir / "flake.lock"))["nodes"]["src"]["locked"]

suite "NF-2: a refreshed pin carries what nix would write":

  test "t_a_refreshed_flake_pin_carries_what_nix_would_write":
    if not nf2Prerequisites(caseName):
      skip("git or the built ./build/bin/repro is missing (named above)")
    else:
      let nixBin = findExe("nix")
      if nixBin.len == 0:
        echo "SKIPPED (loudly): " & caseName & " needs `nix` on PATH: the " &
          "refresh asks nix for the new revision's narHash, and the value it " &
          "writes is checked against `nix flake lock`. nix=MISSING. NOT " &
          "CHECKED by this run: that a moved pin keeps a verifiable narHash."
        skip("nix is not on PATH; this case checks what nix writes")
      else:
        let fx = setupNf2Fixture("derived-fields")
        defer: removeDir(fx.scratch)
        isolateNf2Config(fx)
        defer: releaseNf2Config()

        let before = readFile(lockPath(fx))
        let seedAlpha = fx.seedSha[0]
        let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
        check siblingRevIsPublished(fx, "alpha", newAlpha)

        let commit = tryCommitInApp(fx, "work against a newer alpha")
        checkpoint("commit output:\n" & commit.output)
        checkpoint("pre-commit log:\n" & preCommitLog(fx))
        check commit.code == 0

        let committed = lockInCommit(fx)
        check committed == readFile(lockPath(fx))
        check gitIn(fx, fx.app, "status --porcelain").strip() == ""
        let alphaLocked = parseJson(committed)["nodes"]["alpha-src"]["locked"]
        check alphaLocked["rev"].getStr() == newAlpha

        # ---- (1) the derived fields are present ------------------------
        for field in ["narHash", "lastModified", "revCount"]:
          if not alphaLocked.hasKey(field):
            checkpoint("the moved node has no `" & field & "`:\n" &
              nodeText(committed, "alpha-src"))
          check alphaLocked.hasKey(field)

        # ---- (2) …and equal what nix writes for that revision ----------
        let independent = nixLockedNodeFor(fx, nixBin, "alpha")
        check independent != nil
        if independent != nil:
          check independent["rev"].getStr() == newAlpha
          for field in ["narHash", "lastModified", "revCount"]:
            if alphaLocked{field} != independent{field}:
              checkpoint(field & ": refresh wrote " & shown(alphaLocked{field}) &
                ", nix flake lock wrote " & shown(independent{field}))
            check alphaLocked{field} == independent{field}
          # The independent node is the same input (url, ref, type), so the
          # whole object must agree, not just the three fields.
          check alphaLocked == independent

        # ---- (3) member order is nix's ---------------------------------
        var keys: seq[string]
        for k, _ in alphaLocked.pairs: keys.add(k)
        check keys == sorted(keys)

        # ---- (4) the rest of the document is untouched -----------------
        check nodeText(committed, "beta-src") == nodeText(before, "beta-src")
        check nodeText(committed, "gamma-src") == nodeText(before, "gamma-src")
        check nodeText(committed, "nixpkgs") == nodeText(before, "nixpkgs")
        check before.replace(nodeText(before, "alpha-src"),
          nodeText(committed, "alpha-src")) == committed

        # ---- (5) the hook said so, on the terminal ---------------------
        var announcement = ""
        for line in commit.output.splitLines():
          if line.startsWith("repro pre-commit:") and
              line.contains("alpha-src") and line.contains(newAlpha):
            announcement = line
        checkpoint("announcement: " & announcement)
        check announcement.len > 0
        check announcement.contains("flake.lock")
        check announcement.contains(seedAlpha)
        check announcement.contains(newAlpha)
        check announcement.contains(siblingDir(fx, "alpha"))
        check announcement.contains("staged into this commit")
        check announcement.contains("REPRO_SKIP_LOCK_REFRESH")
        check not commit.output.contains("NOT refreshed")

  test "a changed parent dependency graph is withheld; unchanged locks move":
    # Each dependency lock is generated by real Nix against local git origins.
    # No synthetic metadata or fake dependency resolver participates.
    doAssert nf2RecordingPrerequisites(caseName)
    for transition in ["replace", "add", "remove", "unreadable", "unchanged", "reformatted", "source-only"]:
      let fx = setupNf2Fixture("child-lock-" & transition)
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      let alpha = siblingDir(fx, "alpha")
      let nix = q(findExe("nix")) &
        " --extra-experimental-features 'nix-command flakes' flake lock --offline"
      proc lockAlpha(childRev: string) =
        writeFile(alpha / "flake.nix", "{ inputs.child.url = \"git+" &
          originUrl(fx, "gamma") & "?ref=main&rev=" & childRev &
          "\"; outputs = _: {}; }\n")
        discard gitIn(fx, alpha, "add flake.nix")
        discard requireCmd(nix, cwd = alpha)
        discard gitIn(fx, alpha, "add flake.lock")
      if transition != "add":
        lockAlpha(fx.seedSha[2])
        discard moveAndPublishSibling(fx, "alpha", "initial child lock")
      # Use a fresh Nix-generated consumer lock, including alpha's full old
      # child graph, rather than a hand-authored node approximation.
      writeFile(fx.app / "flake.nix", "{ inputs.alpha-src.url = \"git+" &
        originUrl(fx, "alpha") & "?ref=main\"; inputs.sentinel.url = \"git+" &
        originUrl(fx, "beta") & "?ref=main\"; " &
        (if transition == "source-only": "inputs.alpha-src.flake = false; " else: "") &
        "outputs = _: {}; }\n")
      removeFile(lockPath(fx))
      discard gitIn(fx, fx.app, "add flake.nix")
      discard requireCmd(nix, cwd = fx.app)
      let before = readFile(lockPath(fx))
      if transition == "replace":
        let child = moveAndPublishSibling(fx, "gamma", "child revision 2")
        lockAlpha(child)
      elif transition == "add":
        lockAlpha(fx.seedSha[2])
      elif transition == "remove":
        removeFile(alpha / "flake.lock")
        discard gitIn(fx, alpha, "add -u")
      elif transition == "reformatted":
        let ownLock = parseJson(readFile(alpha / "flake.lock"))
        writeFile(alpha / "flake.lock", $(%*{"version": ownLock["version"],
          "root": ownLock["root"], "nodes": ownLock["nodes"]}))
        discard gitIn(fx, alpha, "add flake.lock")
      elif transition in ["unreadable", "source-only"]:
        writeFile(alpha / "flake.lock", "{ invalid JSON\n")
        discard gitIn(fx, alpha, "add flake.lock")
      let newAlpha = moveAndPublishSibling(fx, "alpha", "parent source revision 2")
      check siblingRevIsPublished(fx, "alpha", newAlpha)
      let outcome = run(q(fx.repro) & " flake refresh-lock --flake=" &
        q(fx.app) & " --workspace-root=" & q(fx.ws))
      checkpoint(transition & ": " & outcome.output)
      check nodeText(readFile(lockPath(fx)), "sentinel") ==
        nodeText(before, "sentinel")
      if transition in ["unchanged", "reformatted", "source-only"]:
        check outcome.code == 0
        check parseJson(readFile(lockPath(fx)))["nodes"]["alpha-src"]["locked"]["rev"].getStr() == newAlpha
        if transition in ["unchanged", "reformatted"]:
          check parseJson(readFile(lockPath(fx)))["nodes"]["child"] ==
            parseJson(before)["nodes"]["child"]
        else:
          check not parseJson(readFile(lockPath(fx)))["nodes"]["alpha-src"]["flake"].getBool()
      else:
        check outcome.code == 3
        check readFile(lockPath(fx)) == before
        check outcome.output.contains("dependency lock")
        check outcome.output.contains("nix flake update alpha-src")
        if transition == "replace":
          # The explicit target must win even when the branch advances again.
          discard moveAndPublishSibling(fx, "alpha", "branch beyond target")
          let updated = run(q(fx.repro) & " lock update alpha-src --to " &
            q(newAlpha) & " --repo-root=" & q(fx.app))
          checkpoint(updated.output)
          check updated.code == 0
          let after = parseJson(readFile(lockPath(fx)))["nodes"]
          check nodeText(readFile(lockPath(fx)), "sentinel") ==
            nodeText(before, "sentinel")
          check after["alpha-src"]["locked"]["rev"].getStr() == newAlpha
          check after["alpha-src"]["original"] ==
            parseJson(before)["nodes"]["alpha-src"]["original"]
          check after["child"]["locked"]["rev"] ==
            parseJson(readFile(alpha / "flake.lock"))["nodes"]["child"]["locked"]["rev"]
