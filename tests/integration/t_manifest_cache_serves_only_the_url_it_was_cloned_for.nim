## W8-R3 — the bootstrap manifest cache must serve a URL its OWN checkout,
## and never an incumbent's.
##
## THE DEFECT. ``manifestCachePath`` keys the cache on ``urlSlug``, which is
## many-to-one by construction: ``sanitizeSlugSegment`` keeps ASCII alnum plus
## ``-._`` and maps everything else to ``_``, so ``a:b``, ``a_b`` and ``a@b``
## have always shared one directory (and since W5, so do ``..`` and ``__``).
## ``ensureManifestCache`` then read ``looksLikeGitDir(target)`` as "this entry
## is mine": it fetched from the checkout's OWN ``origin`` and returned
## ``ok = true`` with NO check that the remote matched the URL that was asked
## for. So the first URL to reach a slug owned it, and every colliding URL
## afterwards was served that origin's tree.
##
## WHY IT IS A DIFFERENT CLASS OF OUTCOME FROM ``sharedBarePath``'s
## collisions. A shared bare is an object POOL, wired in through
## ``objects/info/alternates``; the real clone still fetches from its own
## remote and a collision costs a redundant fetch. The manifest cache is a
## shared CHECKOUT that is READ DIRECTLY, and its reader is the
## composer/resolver walking ``projects/*.toml`` — the document that decides
## which repos a workspace clones and from where. Wrong content at the point
## content becomes trust, and it PERSISTS: one bootstrap from a hostile
## spelling poisoned every later bootstrap of the colliding legitimate URL.
##
## THE FIX IS IDENTITY VALIDATION, NOT SLUG INJECTIVITY. Making the slug
## injective would move every entry on disk and orphan every clone already
## cached. Verifying that a checkout is the one that was asked for is cheap,
## local, and works on the entries already present:
## ``inspectManifestCacheEntry`` reads the entry's ``origin`` and compares
## ``canonicalRemoteIdentity``.
##
## WHAT EACH CASE PINS
##
##   1. ``canonicalRemoteIdentity`` — the matching RULE, stated as equalities
##      and inequalities. Catches a rule that is too loose (the hole reopens)
##      and one that is too strict (a legitimate cache never hits).
##   2. ``t_a_colliding_manifest_url_is_not_served_the_incumbents_tree`` — THE
##      decisive case. Two distinct URLs that slug IDENTICALLY (asserted, so
##      the case cannot go vacuous if the slug ever changes) onto two repos
##      with distinct content. The second must not be served the first's tree.
##      Includes the PERSISTENCE property: the poisoned entry must not keep
##      answering on later calls either, and the incumbent must still get its
##      own tree (re-keying must not have evicted it).
##   3. ``t_an_unverifiable_manifest_cache_entry_is_refused_and_not_deleted``
##      — the fail-closed direction, in the two shapes that must stay
##      DISTINGUISHABLE: a repository with no ``origin`` (``mceNoOrigin``) and
##      one whose config cannot be read (``mceUnreadable``). Collapsing error
##      and absence into one value is the root defect this campaign keeps
##      finding, so the status is asserted as a VALUE, not as prose. Both must
##      also leave the directory ON DISK — refusing must not become deleting.
##   4. ``t_a_legitimate_manifest_cache_entry_still_hits`` — the negative
##      direction. The same URL, and every spelling the rule deliberately
##      calls equal, must hit the EXISTING entry: same path, and a sentinel
##      written into the checkout survives. A fix that re-clones constantly is
##      a different defect.
##
## Every case drives the real ``ensureManifestCache`` with a real ``git``
## against real repositories over ``file://``; nothing is offline-mocked and
## nothing needs the network.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, NOT `check` and NOT `quit`. Under the pinned Nim 2.2.8,
  ## `unittest.fail` outside a test body takes the `setProgramResult 1` branch,
  ## so a `check` in a helper prints "Check failed" and the test still reports
  ## `[OK]` — a silently masked result. `doAssert` raises, and unittest's own
  ## handler turns that into a real failure.
  let res = runCmd(command, cwd)
  doAssert res.code == 0,
    "fixture command failed: " & command & "\nexit=" & $res.code & "\n" &
      res.output
  res.output

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"W8R3 Tester\"")

proc manifestBody(marker: string): string =
  ## The project TOML the composer/resolver would read out of the cache. The
  ## marker is what makes "whose tree did I get" answerable at all.
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "# provenance-marker: " & marker & "\n\n" &
  "includes = []\n"

proc seedManifestBare(gitBin, scratch, barePath, marker: string): string =
  ## Seed a bare manifest repo whose `projects/myproject.toml` carries
  ## `marker`. Returns the HEAD sha.
  ##
  ## The body is DERIVED FROM THE MARKER rather than constant. Two fixtures
  ## with identical bodies committed inside the same second produce the SAME
  ## sha, and a case that then compares trees passes for the wrong reason —
  ## a false PASS this campaign has already paid for once.
  let workPath = scratch / ("seed-" & marker)
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -q -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  createDir(workPath / "projects")
  writeFile(workPath / "projects" / "myproject.toml", manifestBody(marker))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -q -m " &
    q("fixture " & marker))
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone -q --bare " & q(workPath) & " " &
    q(barePath))
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc servedMarker(checkoutPath: string): string =
  ## The provenance marker of the tree `ensureManifestCache` handed back, or
  ## "" when there is no readable project TOML there.
  let toml = checkoutPath / "projects" / "myproject.toml"
  if not fileExists(toml):
    return ""
  for line in readFile(toml).splitLines:
    let trimmed = line.strip()
    if trimmed.startsWith("# provenance-marker:"):
      return trimmed[len("# provenance-marker:") .. ^1].strip()
  ""

suite "W8-R3 — the manifest cache serves only the URL it was cloned for":

  test "canonicalRemoteIdentity separates repositories and unifies spellings":
    ## The matching RULE, in both directions. These are pure-string checks so
    ## they hold on every platform and need no git.

    # --- EQUAL: the spellings the rule deliberately unifies -----------------
    # The scheme. This is not a concession; it is the equivalence `urlSlug`'s
    # own documented examples were built on (the https and scp spellings of
    # one GitHub repo map to one slug), so an identity that required scheme
    # equality would disagree with the key it guards.
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("ssh://h/o/r.git")
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("git@h:o/r.git")
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("git://h/o/r.git")
    # A trailing `.git` and a trailing `/`.
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("https://h/o/r")
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("https://h/o/r.git/")
    # Userinfo — whose credentials are used is not a property of the repo.
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("https://alice@h/o/r.git")
    # Host case — DNS is case-insensitive.
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("https://H/o/r.git")
    # A redundant DEFAULT port, per scheme.
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("https://h:443/o/r.git")
    check canonicalRemoteIdentity("ssh://h/o/r.git") ==
      canonicalRemoteIdentity("ssh://h:22/o/r.git")
    # Empty path segments, matching what the slug does with them.
    check canonicalRemoteIdentity("https://h/o/r.git") ==
      canonicalRemoteIdentity("https://h//o///r.git")

    # --- NOT EQUAL: what it refuses to fold, and the slug does --------------
    # These are THE defect. Each left/right pair shares one `urlSlug`, so
    # before the fix each pair shared one cached checkout. The slug equality
    # is asserted alongside so the case says plainly that the identity is
    # finer than the key it guards.
    for (a, b) in [
        ("https://h/a:b/r.git", "https://h/a_b/r.git"),
        ("https://h/a@b/r.git", "https://h/a_b/r.git"),
        ("https://h/../victim.git", "https://h/__/victim.git"),
        ("https://h/./victim.git", "https://h/_/victim.git")]:
      checkpoint("colliding slug pair: " & a & "  vs  " & b)
      check urlSlug(a) == urlSlug(b)
      check canonicalRemoteIdentity(a) != canonicalRemoteIdentity(b)

    # Path case is NOT folded: some forges fold it and some servers do not,
    # and the URL does not say which. Folding would be a guess in the unsafe
    # direction.
    check canonicalRemoteIdentity("https://h/O/r.git") !=
      canonicalRemoteIdentity("https://h/o/r.git")
    # A NON-default port is a different endpoint.
    check canonicalRemoteIdentity("https://h:8443/o/r.git") !=
      canonicalRemoteIdentity("https://h/o/r.git")
    # And a different host is a different repository.
    check canonicalRemoteIdentity("https://h1/o/r.git") !=
      canonicalRemoteIdentity("https://h2/o/r.git")

  test "t_a_colliding_manifest_url_is_not_served_the_incumbents_tree":
    ## THE decisive case: two distinct URLs, one slug, and the second must not
    ## be handed the first's tree — now, or on any later call.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-w8r3-collision-", "")
      defer: removeDirEventually(scratch)

      # `@` sanitizes to `_`, so these two DISTINCT directories slug to one
      # cache path. This is the pre-existing `a:b` / `a_b` / `a@b` family
      # named in `sanitizeSlugSegment`, expressed as real repositories.
      let incumbentBare = scratch / "collide@x.git"
      let arrivingBare = scratch / "collide_x.git"
      let incumbentSha = seedManifestBare(gitBin, scratch, incumbentBare,
        "incumbent")
      let arrivingSha = seedManifestBare(gitBin, scratch, arrivingBare,
        "arriving")

      # Non-vacuity, part one: the two fixtures are genuinely different
      # commits. Identical bodies committed in the same second would produce
      # the same sha and every content check below would pass for the wrong
      # reason.
      check incumbentSha != arrivingSha

      let incumbentUrl = fileUrl(incumbentBare)
      let arrivingUrl = fileUrl(arrivingBare)
      let cacheRoot = scratch / "manifest-cache"

      # Non-vacuity, part two: the collision is REAL. If the slug ever became
      # injective this assertion fires rather than the case quietly becoming a
      # test of nothing.
      checkpoint("incumbent url: " & incumbentUrl)
      checkpoint("arriving  url: " & arrivingUrl)
      check incumbentUrl != arrivingUrl
      check manifestCachePath(cacheRoot, incumbentUrl) ==
        manifestCachePath(cacheRoot, arrivingUrl)

      # (1) The incumbent bootstraps first and takes the slug.
      let first = ensureManifestCache(gitBin, cacheRoot, incumbentUrl)
      checkpoint("first.ok=" & $first.ok & " path=" & first.sharedBarePath &
        " diagnostic=" & first.diagnostic)
      check first.ok
      check first.sharedBarePath == manifestCachePath(cacheRoot, incumbentUrl)
      check servedMarker(first.sharedBarePath) == "incumbent"

      # (2) The colliding URL asks for ITS manifest. Before the fix this
      # returned ok = true with the incumbent's tree, because presence at the
      # slug was read as ownership.
      let second = ensureManifestCache(gitBin, cacheRoot, arrivingUrl)
      checkpoint("second.ok=" & $second.ok & " path=" & second.sharedBarePath &
        " entry=" & $second.manifestEntry & " diagnostic=" & second.diagnostic)
      check second.ok
      check servedMarker(second.sharedBarePath) == "arriving"
      check servedMarker(second.sharedBarePath) != "incumbent"
      # It was re-keyed, not served in place.
      check second.sharedBarePath !=
        manifestCachePath(cacheRoot, arrivingUrl)
      check second.sharedBarePath ==
        disambiguatedManifestCachePath(cacheRoot, arrivingUrl)
      # ...and the re-keyed path is still INSIDE the cache root.
      let normRekeyed = os.normalizedPath(absolutePath(second.sharedBarePath))
      let normRoot = os.normalizedPath(absolutePath(cacheRoot))
      check normRekeyed.len > normRoot.len
      check normRekeyed.startsWith(normRoot & $DirSep)

      # (3) PERSISTENCE. The poisoning was never a one-shot: the incumbent's
      # tree stayed at the slug and answered every LATER bootstrap of the
      # colliding URL too. Ask again — twice, so a fix that merely repaired
      # the first call is caught.
      for round in 1 .. 2:
        checkpoint("persistence round " & $round)
        let again = ensureManifestCache(gitBin, cacheRoot, arrivingUrl)
        check again.ok
        check again.sharedBarePath == second.sharedBarePath
        check servedMarker(again.sharedBarePath) == "arriving"

      # (4) And re-keying must not have EVICTED the incumbent: its own URL
      # still resolves to its own tree at its own path.
      let incumbentAgain = ensureManifestCache(gitBin, cacheRoot, incumbentUrl)
      check incumbentAgain.ok
      check incumbentAgain.sharedBarePath ==
        manifestCachePath(cacheRoot, incumbentUrl)
      check servedMarker(incumbentAgain.sharedBarePath) == "incumbent"

  test "t_an_unverifiable_manifest_cache_entry_is_refused_and_not_deleted":
    ## Fail closed when identity cannot be ESTABLISHED — and keep the two
    ## unreadable shapes distinguishable as VALUES.
    ##
    ## Before the fix both of these returned ok = true: `looksLikeGitDir` was
    ## satisfied, the `git fetch origin` failed, and the failure branch handed
    ## the caller the unverified checkout with a "using existing checkout"
    ## note. An error was being reported as a success with a comment.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-w8r3-unverifiable-", "")
      defer: removeDirEventually(scratch)

      let originBare = scratch / "origin-manifest.git"
      discard seedManifestBare(gitBin, scratch, originBare, "genuine")
      let manifestUrl = fileUrl(originBare)

      for (arm, expected) in [("no-origin", mceNoOrigin),
                              ("bad-config", mceUnreadable)]:
        let cacheRoot = scratch / ("cache-" & arm)
        let entryPath = manifestCachePath(cacheRoot, manifestUrl)
        createDir(entryPath.splitPath.head)

        # Both arms build a REAL repository at the entry, so git's repository
        # discovery stops there and cannot walk up into whatever encloses the
        # scratch dir. Only then is the identity made unanswerable.
        discard requireGit(q(gitBin) & " init -q -b main " & q(entryPath))
        writeFile(entryPath / "SENTINEL.txt", "must survive a refusal\n")
        if arm == "bad-config":
          # An unterminated section header: git finds the repo and then
          # cannot read its config (exit 128), which is a different thing
          # from finding no `origin` key (exit 1, empty output).
          writeFile(entryPath / ".git" / "config", "[core\n")

        checkpoint("arm=" & arm & " entry=" & entryPath)
        # The entry satisfies the OLD predicate — `looksLikeGitDir` accepts a
        # `.git` directory — which is exactly why the old code served it.
        check dirExists(entryPath / ".git")

        let inspected = inspectManifestCacheEntry(gitBin, entryPath,
          manifestUrl)
        checkpoint("  status=" & $inspected.status & " detail=" &
          inspected.detail)
        check inspected.status == expected

        let res = ensureManifestCache(gitBin, cacheRoot, manifestUrl)
        checkpoint("  ok=" & $res.ok & " entry=" & $res.manifestEntry &
          " diagnostic=" & res.diagnostic)
        # Refused...
        check not res.ok
        # ...for the right, DISTINGUISHABLE reason...
        check res.manifestEntry == expected
        check res.diagnostic.len > 0
        # ...and the refusal did not become a delete. The clone path's
        # recovery step is a `removeDir` of the destination, so falling
        # through to it instead of refusing here would destroy a directory we
        # had merely failed to identify.
        check dirExists(entryPath)
        check fileExists(entryPath / "SENTINEL.txt")

  test "t_a_legitimate_manifest_cache_entry_still_hits":
    ## The negative direction. A fix that re-clones on every call would close
    ## the hole and break the cache, which is a different defect, so the
    ## ordinary hit — and every spelling the rule deliberately calls equal —
    ## must land on the SAME entry without re-cloning it.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-w8r3-cachehit-", "")
      defer: removeDirEventually(scratch)

      let originBare = scratch / "origin-manifest.git"
      discard seedManifestBare(gitBin, scratch, originBare, "genuine")
      let cacheRoot = scratch / "manifest-cache"
      let canonicalUrl = fileUrl(originBare)

      let cold = ensureManifestCache(gitBin, cacheRoot, canonicalUrl)
      checkpoint("cold.ok=" & $cold.ok & " path=" & cold.sharedBarePath &
        " diagnostic=" & cold.diagnostic)
      check cold.ok
      check cold.sharedBarePath == manifestCachePath(cacheRoot, canonicalUrl)
      check servedMarker(cold.sharedBarePath) == "genuine"

      # The sentinel is what makes "hit" observable. A re-clone removes and
      # recreates the destination, so the sentinel cannot survive one; a
      # re-key returns a different path. Either failure is caught.
      let sentinel = cold.sharedBarePath / "CACHE-SENTINEL.txt"
      writeFile(sentinel, "written after the cold clone\n")

      # `fileUrl(originBare)` ends in `.git`; the two variants drop it and
      # add a trailing slash respectively. `normalizeFetchUrl` folds both, and
      # the identity is built on that same decomposition, so all three are one
      # repository.
      let equivalentSpellings = @[
        canonicalUrl,
        canonicalUrl[0 ..< canonicalUrl.len - 4],
        canonicalUrl & "/"]
      for spelling in equivalentSpellings:
        checkpoint("equivalent spelling: " & spelling)
        check canonicalRemoteIdentity(spelling) ==
          canonicalRemoteIdentity(canonicalUrl)
        let warm = ensureManifestCache(gitBin, cacheRoot, spelling)
        checkpoint("  ok=" & $warm.ok & " path=" & warm.sharedBarePath &
          " entry=" & $warm.manifestEntry & " diagnostic=" & warm.diagnostic)
        check warm.ok
        check warm.manifestEntry == mceMatches
        check warm.sharedBarePath == cold.sharedBarePath
        check servedMarker(warm.sharedBarePath) == "genuine"
        # THE hit assertion: the entry was reused, not rebuilt.
        check fileExists(sentinel)

      # No re-keyed sibling was created for a URL that never needed one.
      check not dirExists(
        disambiguatedManifestCachePath(cacheRoot, canonicalUrl))
