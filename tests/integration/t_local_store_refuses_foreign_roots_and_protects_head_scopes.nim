## The local certificate store's safety rules (test-certificates Transport
## §2.3, §2.5 at spec 9ebbcb3; Conformance §5 "Store access" and "Pruning
## protection"), exercised through reprobuild's REAL writer and pruner:
##
##   1. An existing user root owned by ANOTHER account — even one this
##      process can write (a world-writable directory given to a subordinate
##      uid, inside this test's own scratch directory) — is refused by the
##      writer before any mutation, its ``.write-lock`` included, and by the
##      pruner before anything is renamed or deleted. Its contents are left
##      exactly as they were.
##   2. A record file is ``0600`` and a newly created root ``0700`` whatever
##      the umask (``0`` here, which would otherwise leave ``0666``).
##   3. Pruning protects ``HEAD``'s content in BOTH the native ``git-tree-*``
##      algorithm and ``manifest-v1-sha256``, unscoped AND in every scope the
##      repository DECLARES (Tooling §3.1, ``[testCertificatesScope "<n>"]
##      path = …``), computed from ``HEAD`` alone — a staged edit does not
##      move it — while an undeclared scope and unrelated content are pruned,
##      even with ``keep = 0``.
##   4. When ``HEAD`` exists but one of its ids cannot be computed — its tree
##      object is missing, or the scope declaration is invalid — the prune
##      ABORTS before deleting anything, interrupted-prune leftovers
##      included, and says so. An unborn branch and a directory outside any
##      repository have nothing to protect: the prune runs (the positive
##      controls).
##
## Falsifiability: drop ``userRootOwnerProblem`` from the writer → 1 writes
## into the foreign root; create the record with ``open(fmWrite)`` → 2 sees
## ``0666``; protect only ``HEAD^{tree}`` (the previous ``headContentDir``)
## → 3 loses the manifest and scoped directories; prune on a failed
## protection → 4 deletes the unrelated directory and the leftover.
##
## Real filesystem, real git. No mocks.

import repro_test_support/reasoned_skip
import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, times,
            unittest]
when not defined(windows):
  from std/posix import umask, Mode, geteuid, Stat, stat

import repro_cli_support
import repro_cli_support/content_id

proc gitOut(dir: string; args: varargs[string]): string =
  var argv = @["git", "-C", dir]
  for a in args: argv.add(a)
  let res = execCmdEx(quoteShellCommand(argv))
  doAssert res.exitCode == 0, argv.join(" ") & " failed:\n" & res.output
  res.output.strip()

proc newRepo(dir: string; commit = true) =
  createDir(dir)
  discard gitOut(dir, "init", "-q", "-b", "main")
  discard gitOut(dir, "config", "user.email", "tester@example.invalid")
  discard gitOut(dir, "config", "user.name", "Store safety")
  if commit:
    createDir(dir / "src")
    createDir(dir / "docs")
    writeFile(dir / "src" / "a.nim", "echo 1\n")
    writeFile(dir / "docs" / "b.md", "# b\n")
    discard gitOut(dir, "add", "-A")
    discard gitOut(dir, "commit", "-q", "-m", "first")

proc certFor(content: string): TestCertificate =
  TestCertificate(schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId, project: "p",
    platform: "linux/amd64", targets: @["t"], result: tcrPassed,
    issuedAt: "2026-10-29T00:00:00Z", issuer: "store-safety",
    vcs: TestCertificateVcs(repo: "p", content: content),
    commands: @[TestCertificateCommand(argv: @["true"])])

proc makeContentDir(root, contentId: string; age = initDuration(days = 30)) =
  ## ``<root>/v1/<algorithm>/<digest>/`` holding one file, ``age`` old.
  let dir = storeContentDir(contentId)
  doAssert dir.ok, contentId
  let path = root / dir.relative.replace('/', DirSep)
  createDir(path)
  writeFile(path / ("0".repeat(64) & ".toml"), "[certificate]\n")
  setLastModificationTime(path, getTime() - age)

proc hasContentDir(root, contentId: string): bool =
  dirExists(root / storeContentDir(contentId).relative.replace('/', DirSep))

proc headId(repo, algorithm: string; scope: openArray[string] = []): string =
  let id = stateContentId(commitUnderEvaluation(repo, "HEAD"), algorithm,
    scope)
  doAssert id.outcome == cioComputed, id.reason
  id.id

const
  unrelated = "git-tree-sha1:" & "1".repeat(40)
  fresh = "git-tree-sha1:" & "f".repeat(40)

suite "local store: foreign roots, record modes, HEAD protection":

  test "t_local_store_refuses_foreign_roots_and_protects_head_scopes":
    let scratch = createTempDir("repro-store-safety-", "")
    defer: removeDir(scratch)

    # ---- 1. a foreign user root is refused before any mutation -----------
    when defined(windows):
      skip("the foreign-owner case needs a directory owned by another " &
        "account; making one needs a POSIX user namespace")
    else:
      # The foreign root lives INSIDE this test's scratch directory, so even
      # a writer that ignored the owner check could not touch anything
      # outside it. It is made foreign with a user namespace that maps this
      # account's subordinate ids (`unshare --map-users=auto`): inside it
      # this account is root and gives the directory to `nobody` (65534),
      # which outside is a subordinate uid — a real other account — and
      # opens it to everyone, so the writer COULD write there (Transport
      # §2.3: "even when that root is writable by the caller"). Without
      # subordinate ids the root falls back to `/`, owned by root and NOT
      # writable here: still foreign, and nothing can be written to it
      # whatever the writer does.
      let made = scratch / "foreign-root"
      createDir(made)
      let unshare = findExe("unshare")
      let mapped =
        unshare.len > 0 and execCmdEx(quoteShellCommand([unshare, "--user",
          "--map-root-user", "--map-users=auto", "--map-groups=auto", "sh",
          "-c", "chown 65534:65534 \"$1\" && chmod 0777 \"$1\"", "sh",
          made])).exitCode == 0
      var st: Stat
      let foreign =
        if mapped and stat(made.cstring, st) == 0 and st.st_uid != geteuid():
          made
        else:
          checkpoint("no user namespace with subordinate ids; using '/' " &
            "(foreign but not writable) as the foreign root")
          "/"
      check stat(foreign.cstring, st) == 0
      check st.st_uid != geteuid()
      var before: seq[string]
      for _, path in walkDir(foreign): before.add(path)
      before.sort()
      let published = publishCertificateDocument(foreign,
        serializeCertificateToToml(certFor(fresh)))
      checkpoint("foreign root '" & foreign & "': " & published.error)
      check published.error.len > 0
      check "owned by uid" in published.error
      check not fileExists(foreign / ".write-lock")
      check not dirExists(foreign / "v1")
      let viaProducer = publishCertificateToLocalStore(certFor(fresh), "",
        CertificateStoreRoots(user: foreign))
      check not viaProducer.written
      check viaProducer.error.len > 0
      check not fileExists(foreign / ".write-lock")
      let pruned = pruneStoreRoot(foreign, 0, [])
      checkpoint("foreign prune: " & pruned.errors.join("; "))
      check pruned.errors.len > 0
      check pruned.removed.len == 0
      var after: seq[string]
      for _, path in walkDir(foreign): after.add(path)
      after.sort()
      check after == before

    # ---- 2. owner-only modes whatever the umask --------------------------
    when not defined(windows):
      let previous = umask(Mode(0))
      try:
        let root = scratch / "modes" / "store"
        let published = publishCertificateDocument(root,
          serializeCertificateToToml(certFor(fresh)))
        check published.error == ""
        check getFilePermissions(published.path) ==
          {fpUserRead, fpUserWrite}
        check getFilePermissions(root) ==
          {fpUserRead, fpUserWrite, fpUserExec}
        check getFilePermissions(published.path.parentDir) ==
          {fpUserRead, fpUserWrite, fpUserExec}
      finally:
        discard umask(previous)

    # ---- 3. HEAD protected in both algorithms and every declared scope ---
    let repo = scratch / "repo"
    newRepo(repo)
    discard gitOut(repo, "config", "--add", "testCertificatesScope.src.path",
      "src")
    let protectedIds = @[
      headId(repo, "git-tree-sha1"),
      headId(repo, "manifest-v1-sha256"),
      headId(repo, "git-tree-sha1", ["src"]),
      headId(repo, "manifest-v1-sha256", ["src"])]
    let undeclared = headId(repo, "git-tree-sha1", ["docs"])
    # A staged edit does not move what is protected: protection is HEAD's.
    writeFile(repo / "src" / "a.nim", "echo 2\n")
    discard gitOut(repo, "add", "-A")
    let root = scratch / "protect" / "store"
    for id in protectedIds & @[undeclared, unrelated]:
      makeContentDir(root, id)
    let protection = headPruneProtection(repo)
    check protection.ok
    for id in protectedIds:
      check storeContentDir(id).relative in protection.dirs
    check storeContentDir(undeclared).relative notin protection.dirs
    let delivered = publishCertificateToLocalStore(certFor(fresh), repo,
      CertificateStoreRoots(user: root), keep = 0)
    checkpoint("protect: " & delivered.pruned.errors.join("; "))
    check delivered.written
    check delivered.pruned.errors.len == 0
    for id in protectedIds:
      checkpoint("protected " & id)
      check hasContentDir(root, id)
    check hasContentDir(root, fresh)          # the one just written
    check not hasContentDir(root, undeclared)
    check not hasContentDir(root, unrelated)

    # ---- 4. an uncomputable HEAD id aborts the prune ---------------------
    proc leftover(root: string): string =
      root / "v1" / "git-tree-sha1" / ("." & "2".repeat(40) & ".removing-1-1")

    proc abortCase(label, repo: string) =
      let root = scratch / ("abort-" & label) / "store"
      makeContentDir(root, unrelated)
      createDir(leftover(root))
      let delivered = publishCertificateToLocalStore(certFor(fresh), repo,
        CertificateStoreRoots(user: root), keep = 0)
      checkpoint(label & ": " & delivered.pruned.errors.join("; "))
      check delivered.written                  # delivery is not undone
      check delivered.pruned.errors.anyIt("was not pruned" in it)
      check delivered.pruned.removed.len == 0
      check hasContentDir(root, unrelated)
      check dirExists(leftover(root))

    # (a) an invalid scope declaration (Tooling §3.1: not a scope path).
    let badScope = scratch / "bad-scope"
    newRepo(badScope)
    discard gitOut(badScope, "config", "--add",
      "testCertificatesScope.bad.path", "/absolute")
    check not headPruneProtection(badScope).ok
    abortCase("invalid-declaration", badScope)

    # (b) HEAD's tree object is gone, so no id of HEAD can be computed.
    let broken = scratch / "broken-head"
    newRepo(broken)
    let tree = gitOut(broken, "rev-parse", "HEAD^{tree}")
    let looseTree = broken / ".git" / "objects" / tree[0 .. 1] / tree[2 .. ^1]
    require fileExists(looseTree)
    setFilePermissions(looseTree, {fpUserRead, fpUserWrite})
    removeFile(looseTree)
    check not headPruneProtection(broken).ok
    abortCase("missing-head-tree", broken)

    # Positive controls: nothing to protect, so the prune RUNS.
    proc prunesCase(label, repo: string) =
      let root = scratch / ("prunes-" & label) / "store"
      makeContentDir(root, unrelated)
      createDir(leftover(root))
      let delivered = publishCertificateToLocalStore(certFor(fresh), repo,
        CertificateStoreRoots(user: root), keep = 0)
      checkpoint(label & ": " & delivered.pruned.errors.join("; "))
      check delivered.written
      check delivered.pruned.errors.len == 0
      check not hasContentDir(root, unrelated)
      check not dirExists(leftover(root))
      check hasContentDir(root, fresh)

    let unborn = scratch / "unborn"
    newRepo(unborn, commit = false)
    let unbornProtection = headPruneProtection(unborn)
    check unbornProtection.ok and unbornProtection.dirs.len == 0
    prunesCase("unborn-branch", unborn)
    let outside = scratch / "not-a-repo"
    createDir(outside)
    check headPruneProtection(outside).ok
    prunesCase("not-a-repository", outside)
