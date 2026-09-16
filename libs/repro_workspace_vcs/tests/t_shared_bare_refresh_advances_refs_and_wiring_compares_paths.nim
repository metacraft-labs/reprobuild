## Shared bare-clone cache — the two properties the cache silently lacked.
##
## Spec: ``reprobuild-specs/Workspace-And-Develop-Mode.md`` §"Clone
## acceleration: shared object cache".
##
## No mocks. Every case drives the real ``git`` binary against real bare
## repositories in a temp directory, because both properties under test are
## statements about what git itself does with a refspec and with an
## ``objects/info/alternates`` entry. A fake would agree with whatever this
## file asserted and prove nothing — which is exactly how both defects
## survived: the cache's own "refresh" exited 0 every time it did nothing.
##
## Cases:
##
##   - ``refresh_advances_heads_of_a_bare_cloned_without_a_refspec`` — the
##     defect itself. ``git clone --bare`` sets no ``remote.origin.fetch``,
##     so ``git fetch --all --prune`` in the bare updates ``FETCH_HEAD``
##     and NOTHING else: ``refs/heads/*`` stays frozen at clone time, the
##     pre-rewrite history stays reachable forever, and the ``git gc
##     --prune=now`` in ``maintainSharedBare`` can never drop it. The case
##     asserts the un-migrated shape first (so the premise is real, not
##     assumed), then that ``refreshSharedBare`` advances the ref.
##
##   - ``migration_is_in_place_and_keeps_the_cache_refs`` — an EXISTING
##     bare in a user's cache is migrated by one config write, with no
##     re-clone; and the refspec chosen is heads-only rather than a mirror
##     precisely so that ``pushCacheRef``'s ``refs/cache/<workspace>/*`` —
##     refs that exist on no remote — survive the ``--prune``. Under a
##     mirror refspec the very next refresh deletes them.
##
##   - ``wiring_is_recognised_whoever_wrote_the_alternates_entry`` —
##     ``isWiredTo`` compared ``sharedBarePath / "objects"`` to the
##     alternates file as an exact string. ``wireAlternates`` writes Nim's
##     separator (a backslash on Windows); ``git clone --reference`` writes
##     git's, a forward slash on every platform. So every repo git itself
##     wired reported ``wired=false`` — measured on a real workspace, 162 of
##     162. The case asserts BOTH directions and a genuine negative, so a
##     "return true" cannot pass it.
##
## Skip rule: ``git`` missing on PATH (the convention the workspace suite
## already follows).

import std/[os, osproc, strutils, tempfiles, unittest]

import shared_clones

proc q(value: string): string = quoteShell(value)

proc git(gitBin, cwd: string; args: varargs[string]): tuple[code: int;
                                                            output: string] =
  var cmd = q(gitBin)
  cmd.add(" -C " & q(cwd))
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc gitTop(gitBin: string; args: varargs[string]): tuple[code: int;
                                                          output: string] =
  var cmd = q(gitBin)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc requireGit(gitBin, cwd: string; args: varargs[string]): string =
  let res = git(gitBin, cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
    check res.code == 0
  res.output

proc seedUpstream(gitBin, upstream, work: string): string =
  ## A bare upstream with one commit on ``main``, plus a working clone from
  ## which further commits are pushed. Returns the first commit's SHA.
  discard gitTop(gitBin, "init", "--bare", "-b", "main", upstream)
  discard gitTop(gitBin, "init", "-b", "main", work)
  discard git(gitBin, work, "config", "user.email", "tester@example.invalid")
  discard git(gitBin, work, "config", "user.name", "Cache Tester")
  writeFile(work / "a.txt", "one\n")
  discard requireGit(gitBin, work, "add", "a.txt")
  discard requireGit(gitBin, work, "commit", "-m", "one")
  discard requireGit(gitBin, work, "remote", "add", "origin", upstream)
  discard requireGit(gitBin, work, "push", "origin", "main")
  requireGit(gitBin, work, "rev-parse", "HEAD")

proc pushSecondCommit(gitBin, work: string): string =
  writeFile(work / "b.txt", "two\n")
  discard requireGit(gitBin, work, "add", "b.txt")
  discard requireGit(gitBin, work, "commit", "-m", "two")
  discard requireGit(gitBin, work, "push", "origin", "main")
  requireGit(gitBin, work, "rev-parse", "HEAD")

suite "shared bare-clone cache — refresh and wiring":

  test "t_shared_bare_refresh_advances_heads_of_a_bare_cloned_without_a_refspec":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sharedbare-refresh-", "")
      defer: removeDir(scratch)
      let upstream = scratch / "upstream.git"
      let work = scratch / "work"
      let firstSha = seedUpstream(gitBin, upstream, work)

      # A cache root whose bare for this URL does not exist yet, so the
      # first ``refreshSharedBare`` is the clone arm.
      let cacheRoot = scratch / "cache"
      let bare = sharedBarePath(cacheRoot, upstream)
      let created = refreshSharedBare(gitBin, cacheRoot, upstream)
      check created.ok
      check created.sharedBarePath == bare
      check requireGit(gitBin, bare, "rev-parse", "refs/heads/main") == firstSha

      # THE PREMISE, asserted rather than assumed: a plain ``clone --bare``
      # carries no fetch refspec, and a fetch in such a bare exits 0 having
      # advanced nothing. Reproduce that on a second, deliberately
      # un-migrated copy of the same bare so the case proves the defect it
      # claims to fix rather than trusting the description of it.
      let unmigrated = scratch / "unmigrated.git"
      discard gitTop(gitBin, "clone", "--bare", "--quiet", upstream, unmigrated)
      let noRefspec = git(gitBin, unmigrated, "config", "--get",
        "remote.origin.fetch")
      check noRefspec.code != 0          # the key is absent, not empty
      check noRefspec.output.len == 0

      let secondSha = pushSecondCommit(gitBin, work)
      check secondSha != firstSha

      let staleFetch = git(gitBin, unmigrated, "fetch", "--all", "--prune",
        "--quiet")
      check staleFetch.code == 0         # it SUCCEEDS ...
      check requireGit(gitBin, unmigrated, "rev-parse",
        "refs/heads/main") == firstSha   # ... and advances nothing.

      # The fix: the cache's own refresh advances the ref. Asserting the
      # fetch's EXIT CODE here would pass against the defect — the stale
      # fetch above exits 0 too. The ref is the only thing that tells them
      # apart.
      let refreshed = refreshSharedBare(gitBin, cacheRoot, upstream)
      check refreshed.ok
      check requireGit(gitBin, bare, "rev-parse", "refs/heads/main") == secondSha
      check requireGit(gitBin, bare, "config", "--get",
        "remote.origin.fetch") == SharedBareFetchRefspec
      check requireGit(gitBin, bare, "config", "--get",
        "remote.origin.prune").toLowerAscii() == "true"

      # And the OTHER half of a refresh: a ref that no longer exists
      # upstream is removed, so the history behind it stops being reachable
      # and ``maintainSharedBare``'s gc can finally collect it. Under the
      # defect the prune was as inert as the fetch — branches deleted from
      # the remote months earlier were still sitting in the bare.
      discard requireGit(gitBin, work, "switch", "-c", "doomed")
      discard requireGit(gitBin, work, "push", "origin", "doomed")
      check refreshSharedBare(gitBin, cacheRoot, upstream).ok
      check git(gitBin, bare, "rev-parse", "refs/heads/doomed").code == 0
      discard requireGit(gitBin, work, "push", "origin", "--delete", "doomed")
      check refreshSharedBare(gitBin, cacheRoot, upstream).ok
      check git(gitBin, bare, "rev-parse", "refs/heads/doomed").code != 0

  test "t_shared_bare_migration_is_in_place_and_keeps_the_cache_refs":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sharedbare-migrate-", "")
      defer: removeDir(scratch)
      let upstream = scratch / "upstream.git"
      let work = scratch / "work"
      let firstSha = seedUpstream(gitBin, upstream, work)

      # A bare that a PREVIOUS reprobuild created: cloned with ``--bare``,
      # no refspec, already populated. Migration must not re-clone it.
      let cacheRoot = scratch / "cache"
      let bare = sharedBarePath(cacheRoot, upstream)
      createDir(parentDir(bare))
      discard gitTop(gitBin, "clone", "--bare", "--quiet", upstream, bare)
      check git(gitBin, bare, "config", "--get",
        "remote.origin.fetch").code != 0
      # RA-5's cross-workspace mechanism: a sibling workspace's objects
      # published into the bare under a ref that exists on NO remote.
      discard requireGit(gitBin, bare, "update-ref",
        "refs/cache/sibling-workspace/main", firstSha)
      let markerPath = bare / "MIGRATION-MARKER"
      writeFile(markerPath, "this bare was not re-cloned\n")

      let secondSha = pushSecondCommit(gitBin, work)
      let refreshed = refreshSharedBare(gitBin, cacheRoot, upstream)
      check refreshed.ok

      # In place: the directory is the same one, not a replacement.
      check fileExists(markerPath)
      # Current: the head advanced.
      check requireGit(gitBin, bare, "rev-parse",
        "refs/heads/main") == secondSha
      # And the half git does not know about survived the ``--prune``. This
      # is the assertion that rules out ``--mirror`` / ``+refs/*:refs/*``,
      # under which this ref is deleted on the first refresh.
      check requireGit(gitBin, bare, "rev-parse",
        "refs/cache/sibling-workspace/main") == firstSha

      # Idempotent: a second refresh neither duplicates the refspec nor
      # disturbs the cache ref.
      check refreshSharedBare(gitBin, cacheRoot, upstream).ok
      let refspecs = git(gitBin, bare, "config", "--get-all",
        "remote.origin.fetch")
      check refspecs.code == 0
      check refspecs.output.splitLines().len == 1
      check requireGit(gitBin, bare, "config", "--get",
        "remote.origin.prune").toLowerAscii() == "true"
      check requireGit(gitBin, bare, "rev-parse",
        "refs/cache/sibling-workspace/main") == firstSha

  test "t_shared_bare_wiring_is_recognised_whoever_wrote_the_alternates_entry":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sharedbare-wiring-", "")
      defer: removeDir(scratch)
      let upstream = scratch / "upstream.git"
      let work = scratch / "work"
      discard seedUpstream(gitBin, upstream, work)
      let cacheRoot = scratch / "cache"
      let bare = sharedBarePath(cacheRoot, upstream)
      check refreshSharedBare(gitBin, cacheRoot, upstream).ok

      # (1) Written by GIT: ``clone --reference`` records the alternates
      # entry in git's own spelling — forward slashes on every platform,
      # including Windows, where ``sharedBarePath / "objects"`` is spelled
      # with backslashes. This is the direction that reported ``wired=false``
      # for every repo in a real 162-repo workspace.
      let gitWired = scratch / "git-wired"
      discard gitTop(gitBin, "clone", "--quiet", "--reference", bare,
        upstream, gitWired)
      let entries = readAlternates(gitWired)
      check entries.len == 1
      check isWiredTo(gitWired, bare)

      # (2) Written by US: ``wireAlternates`` must still be recognised, so
      # the normalisation did not trade one direction for the other.
      let selfWired = scratch / "self-wired"
      discard gitTop(gitBin, "clone", "--quiet", upstream, selfWired)
      check not isWiredTo(selfWired, bare)
      check wireAlternates(selfWired, bare).ok
      check isWiredTo(selfWired, bare)

      # (3) A genuine negative, so neither (1) nor (2) can be satisfied by a
      # predicate that always answers yes: a repo wired to a DIFFERENT bare
      # is not wired to this one.
      let otherBare = scratch / "other-bare.git"
      discard gitTop(gitBin, "clone", "--bare", "--quiet", upstream, otherBare)
      let elsewhere = scratch / "elsewhere"
      discard gitTop(gitBin, "clone", "--quiet", "--reference", otherBare,
        upstream, elsewhere)
      check readAlternates(elsewhere).len == 1
      check isWiredTo(elsewhere, otherBare)
      check not isWiredTo(elsewhere, bare)

      # (4) The normalisation itself: separators and a trailing separator
      # are not part of a path's identity; a different directory is.
      check samePathOnDisk(bare / "objects",
        (bare / "objects").replace('\\', '/'))
      check samePathOnDisk(bare / "objects", bare / "objects" & "/")
      check samePathOnDisk(bare / "objects", bare / "." / "objects")
      check not samePathOnDisk(bare / "objects", otherBare / "objects")
