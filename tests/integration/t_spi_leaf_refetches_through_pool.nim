## A checkout fetches a missing object back through its pool, and a plain
## ``git fetch`` survives a dangling remote-tracking ref.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.4, §3.5
## (SPI-AREQ-2, SPI-AREQ-5, SPI-GOAL-6); milestone SPI-2.
##
## Design. Real ``git`` against real repositories: an upstream, a pool made by
## ``refreshSharedBare`` and a leaf cloned with ``git clone --reference`` and
## then wired with ``wireAlternates`` — the call that writes the leaf's
## ``repro-pool`` promisor remote and ``fetch.hideRefs``.
## Objects are erased from the pool deterministically, by rebuilding its packs
## from ``rev-list --objects --all`` after dropping the ref that kept them;
## a gc in a partial-clone pool could lazily fetch them back and silently heal
## the fixture. Every presence probe runs with ``GIT_NO_LAZY_FETCH=1`` for the
## same reason; only the reads that are SUPPOSED to fetch run without it.
##
## Cases:
##
##   - ``missing_object_comes_back_into_leaf_and_pool`` — upstream still
##     serves a branch whose objects are gone from leaf and pool; reading it
##     in the leaf succeeds and leaves a copy in BOTH (SPI-AREQ-2).
##   - ``mutation_without_uploadpack_override_read_fails`` — the same read
##     with ``remote.repro-pool.uploadpack`` removed fails and fetches
##     nothing: upload-pack refuses to lazily fetch on a client's behalf.
##   - ``fetch_survives_dangling_ref_only_with_hiderefs`` — upstream rewrote a
##     branch and purged the old commit; with ``fetch.hideRefs`` removed,
##     ``git fetch`` dies on the dangling ref (the incident's error); with it,
##     ``git fetch`` succeeds and replaces the ref with upstream's new tip
##     (SPI-AREQ-5).
##   - ``nix_fetchgit_reads_configured_leaf_and_pool`` — ``builtins.fetchGit``
##     (libgit2) reads a configured leaf and a configured pool (SPI-GOAL-6),
##     and — the mutation — FAILS on the same leaf once
##     ``extensions.partialClone`` is added to it. That failure (measured with
##     Nix 2.32.8, 2.34.7 and Determinate Nix 2.34.8: "unsupported extension
##     name extensions.partialclone") is why a leaf gets
##     ``remote.repro-pool.promisor=true`` but not the extension the spec's
##     §3.4 table lists; the first case shows the promisor remote alone still
##     fetches on demand. Its fetcher cache is pointed at the temp root; the
##     store path it adds is content-addressed and inert. Skipped when ``nix``
##     is not on PATH.
##
##   - ``unmigrated_blobless_leaf_is_reported_and_healed_without_missing_tips``
##     — every current ref, commit and tree exists but their blobs do not;
##     fetch does not repair them, on-touch migration is reported, and a
##     subsequent read heals both leaf and pool. Wrong chain keys must also
##     be diagnosed, independently of object presence.
##
## No mocks. Hermetic: one ``createTempDir`` root, a private
## ``GIT_CONFIG_GLOBAL``, ``file://`` URLs throughout (a plain path would make
## git hardlink instead of borrow). Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import shared_clones

proc q(value: string): string = quoteShell(value)

proc run(cwd: string; lazy: bool; args: varargs[string]):
    tuple[code: int; output: string] =
  # Lazy fetching ON is the variable UNSET, as in a user's shell: upload-pack
  # keeps an inherited value, so ``=0`` here would let the pool fetch on the
  # leaf's behalf even without the uploadpack override.
  var cmd = (if lazy: "env -u GIT_NO_LAZY_FETCH " else: "GIT_NO_LAZY_FETCH=1 ") &
    "git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  run(cwd, false, args)

proc must(cwd: string; args: varargs[string]): string =
  let res = gitIn(cwd, args)
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

proc erasePoolUnreachable(pool: string) =
  ## Rebuild the pool's object store from exactly what its refs reach.
  let objects = must(pool, "rev-list", "--objects", "--all")
  var ids = ""
  for line in objects.splitLines():
    let id = line.split(' ')[0].strip()
    if id.len > 0: ids.add(id & "\n")
  let packDir = pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "fresh"), input = ids)
  doAssert packed.exitCode == 0, packed.output
  let keep = "fresh-" & packed.output.strip()
  for kind, f in walkDir(packDir):
    if not f.lastPathPart.startsWith(keep):
      removeFile(f)
  for kind, d in walkDir(pool / "objects"):
    if kind == pcDir and d.lastPathPart.len == 2:
      removeDir(d)

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
"""

type Fixture = object
  root, up, pool, leaf, gitBin: string

proc setUp(root: string): Fixture =
  result.root = root
  result.gitBin = findExe("git")
  result.up = root / "up"
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  let url = "file://" & result.up
  createDir(result.up)
  discard must(result.up, "init", "-q")
  for i in 1 .. 2:
    commitFile(result.up, "m" & $i, $i & "\n")
  discard must(result.up, "checkout", "-q", "-b", "side")
  for i in 1 .. 3:
    commitFile(result.up, "s" & $i, "side " & $i & "\n")
  discard must(result.up, "checkout", "-q", "main")
  let created = refreshSharedBare(result.gitBin, root / "cache", url)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  result.leaf = root / "ws" / "up"
  createDir(result.leaf.parentDir)
  discard must(root, "clone", "-q", "--reference", result.pool, url,
    result.leaf)
  let wired = wireAlternates(result.leaf, result.pool, result.gitBin)
  doAssert wired.ok and wired.diagnostic.len == 0, wired.diagnostic
  # Premise: the leaf holds no objects of its own; everything is borrowed.
  doAssert must(result.leaf, "count-objects", "-v").contains("in-pack: 0")

proc tearDown() =
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

proc loseSideFromPool(f: Fixture): string =
  ## Make ``side``'s objects missing from leaf and pool while upstream still
  ## serves them; returns the side tip.
  result = must(f.leaf, "rev-parse", "refs/remotes/origin/side")
  discard must(f.pool, "update-ref", "-d", "refs/heads/side")
  erasePoolUnreachable(f.pool)
  doAssert not has(f.pool, result) and not has(f.leaf, result)
  doAssert has(f.up, result)

suite "SPI-2: leaves refetch through the pool":

  test "missing_object_comes_back_into_leaf_and_pool":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi2-heal-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # The leaf carries §3.4 (less the format extension) and §3.5.
      check must(f.leaf, "config", "--get", "remote.repro-pool.url") ==
        poolFileUrl(f.pool)
      check must(f.leaf, "config", "--get", "remote.repro-pool.promisor") ==
        "true"
      check must(f.leaf, "config", "--get", "remote.repro-pool.uploadpack") ==
        LeafPoolUploadPack
      check must(f.leaf, "config", "--get",
        "remote.repro-pool.skipFetchAll") == "true"
      check gitIn(f.leaf, "config", "--get", "remote.repro-pool.fetch").code != 0
      # Deliberately NOT written into a leaf: see the module comment.
      check gitIn(f.leaf, "config", "--get", "extensions.partialClone").code != 0
      check must(f.leaf, "config", "--get-all", "fetch.hideRefs") ==
        LeafHiddenFetchRefs
      check must(f.pool, "config", "--get", "extensions.partialClone") ==
        "origin"
      check must(f.pool, "config", "--get", "remote.origin.promisor") == "true"
      let tip = loseSideFromPool(f)
      let read = run(f.leaf, true, "cat-file", "-p", tip & "^{tree}")
      checkpoint("lazy read: " & read.output)
      check read.code == 0
      check has(f.leaf, tip)
      check has(f.pool, tip)               # the pool kept a copy
      check has(f.leaf, tip & "~2")        # the history behind it came too

  test "mutation_without_uploadpack_override_read_fails":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi2-nooverride-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      discard must(f.leaf, "config", "--unset", "remote.repro-pool.uploadpack")
      let tip = loseSideFromPool(f)
      let read = run(f.leaf, true, "cat-file", "-p", tip & "^{tree}")
      checkpoint("lazy read without override: " & read.output)
      check read.code != 0
      check not has(f.leaf, tip)
      check not has(f.pool, tip)

  test "fetch_survives_dangling_ref_only_with_hiderefs":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi2-hiderefs-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let old = must(f.leaf, "rev-parse", "refs/remotes/origin/side")
      # Upstream rewrites side and purges the old commits.
      discard must(f.up, "checkout", "-q", "-B", "side", "main")
      commitFile(f.up, "rewritten", "r\n")
      discard must(f.up, "checkout", "-q", "main")
      discard must(f.up, "reflog", "expire", "--expire=now", "--all")
      discard must(f.up, "gc", "-q", "--prune=now")
      let newTip = must(f.up, "rev-parse", "side")
      doAssert not has(f.up, old)
      check refreshSharedBare(f.gitBin, root / "cache", "file://" & f.up).ok
      # Leave the leaf's ref dangling (a refresh's detector would remove it;
      # this case is about plain git fetch, outside reprobuild).
      if gitIn(f.leaf, "rev-parse", "-q", "--verify",
          "refs/remotes/origin/side").code != 0:
        discard must(f.leaf, "update-ref", "refs/remotes/origin/side", old)
      erasePoolUnreachable(f.pool)
      doAssert not has(f.leaf, old) and not has(f.pool, old)
      # Without fetch.hideRefs: the incident's error.
      discard must(f.leaf, "config", "--unset-all", "fetch.hideRefs")
      let bad = run(f.leaf, true, "fetch", "origin")
      checkpoint("fetch without hideRefs: " & bad.output)
      check bad.code != 0
      check "bad object" in bad.output
      # With it: success, and the ref now names upstream's new tip.
      discard must(f.leaf, "config", "--add", "fetch.hideRefs",
        LeafHiddenFetchRefs)
      let good = run(f.leaf, true, "fetch", "origin")
      checkpoint("fetch with hideRefs: " & good.output)
      check good.code == 0
      check must(f.leaf, "rev-parse", "refs/remotes/origin/side") == newTip

  test "nix_fetchgit_reads_configured_leaf_and_pool":
    if findExe("git").len == 0 or findExe("nix").len == 0:
      skip("needs git and nix on PATH")
    else:
      let root = createTempDir("repro-spi2-nix-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let head = must(f.leaf, "rev-parse", "HEAD")
      for (what, url) in [("leaf", "file://" & f.leaf),
                          ("pool", "file://" & f.pool)]:
        let expr = "(builtins.fetchGit { url = \"" & url & "\"; rev = \"" &
          head & "\"; }).outPath"
        let res = execCmdEx("XDG_CACHE_HOME=" & q(root / "xdg-cache") &
          " nix eval --raw --impure --extra-experimental-features nix-command" &
          " --expr " & q(expr))
        checkpoint("nix fetchGit of the " & what & ": " & res.output)
        check res.exitCode == 0
        if res.exitCode == 0:
          let outPath = res.output.strip().splitLines()[^1]
          check fileExists(outPath / "m2")
      # Mutation: the spec's leaf extension makes the leaf unreadable.
      discard must(f.leaf, "config", "core.repositoryFormatVersion", "1")
      discard must(f.leaf, "config", "extensions.partialClone",
        LeafPoolRemoteName)
      let expr = "(builtins.fetchGit { url = \"file://" & f.leaf &
        "\"; rev = \"" & head & "\"; }).outPath"
      let broken = execCmdEx("XDG_CACHE_HOME=" & q(root / "xdg-cache-2") &
        " nix eval --raw --impure --extra-experimental-features nix-command" &
        " --expr " & q(expr))
      checkpoint("nix fetchGit of a leaf with the extension: " & broken.output)
      check broken.exitCode != 0
      check "partialclone" in broken.output.toLowerAscii

  test "unmigrated_blobless_leaf_is_reported_and_healed_without_missing_tips":
    let root = createTempDir("repro-spi2-unmigrated-", "")
    defer:
      tearDown()
      removeDir(root)
    let f = setUp(root)
    # Keep every commit and tree, but no blobs: the incident's blob:none
    # pool, with current refs intact. Repacking explicitly prevents a lazy
    # fetch or an expiry policy from accidentally healing the fixture.
    let objects = must(f.pool, "rev-list", "--objects", "--all",
      "--filter=blob:none", "--no-object-names")
    let packDir = f.pool / "objects" / "pack"
    let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(f.pool) &
      " pack-objects -q " & q(packDir / "blobless"), input = objects & "\n")
    doAssert packed.exitCode == 0, packed.output
    let keep = "blobless-" & packed.output.strip()
    for kind, path in walkDir(packDir):
      if not path.lastPathPart.startsWith(keep): removeFile(path)
    for kind, path in walkDir(f.pool / "objects"):
      if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
    writeFile(packDir / (keep & ".promisor"), "")
    discard must(f.leaf, "remote", "remove", LeafPoolRemoteName)
    discard must(f.leaf, "config", "--unset-all", "fetch.hideRefs")
    let blob = must(f.up, "rev-parse", "main:m2")
    for line in must(f.leaf, "show-ref").splitLines():
      doAssert has(f.leaf, line.splitWhitespace()[0])
    doAssert has(f.leaf, "HEAD^{tree}")
    doAssert not has(f.leaf, blob) and not has(f.pool, blob)
    # Ordinary fetch succeeds yet leaves current-commit blobs missing.
    check run(f.leaf, true, "fetch", "origin").code == 0
    check not has(f.leaf, blob)
    check run(f.leaf, true, "show", "HEAD:m2").code != 0
    let report = checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache")
    check report.configured
    check report.hasMessages
    check "refetch chain" in messages([report]).join("\n")
    let read = run(f.leaf, true, "show", "HEAD:m2")
    check read.code == 0
    check read.output.splitLines()[^1] == "2"
    check has(f.leaf, blob) and has(f.pool, blob)
    check not checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache").hasMessages
    for (key, value) in [
        ("url", "file:///missing-pool"),
        ("promisor", "false"),
        ("uploadpack", "git-upload-pack"),
        ("skipFetchAll", "false"),
        ("fetch", "+refs/heads/*:refs/remotes/repro-pool/*")]:
      discard must(f.leaf, "config", "remote.repro-pool." & key, value)
      let wrong = checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache")
      checkpoint("incorrect refetch chain key: " & key)
      check wrong.hasMessages
      check wrong.configured
      check "refetch chain" in messages([wrong]).join("\n")
      check not checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache").hasMessages
    for key in ["url", "promisor"]:
      let name = "remote.repro-pool." & key
      let expected = must(f.leaf, "config", "--get", name)
      discard must(f.leaf, "config", "--add", name, expected)
      let duplicate = checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache")
      checkpoint("duplicate refetch chain key: " & key)
      check duplicate.hasMessages
      check duplicate.configured
      check must(f.leaf, "config", "--get-all", name) == expected
      check not checkLeaf(f.gitBin, f.leaf, lcmReport, root / "cache").hasMessages
