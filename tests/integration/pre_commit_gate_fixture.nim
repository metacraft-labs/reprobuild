## TC-8g shared fixture: the TC-8c store workspace with the managed hooks
## installed by the real ``repro hooks ensure --vcs``, so every case drives
## the dispatcher, the managed body and ``repro`` through a real
## ``git commit``.
##
## ``include``d (not imported, not a registered test) by the TC-8g integration
## tests. Like the store fixture it extends, it points the certificate store
## roots at scratch directories in this process's environment, so the hooks a
## commit runs read those roots and never the user's own.
##
## ``REPROBUILD_REPRO`` names the freshly built ``repro`` for every git
## command, because the managed body resolves its interpreter from it before
## ``PATH``: a dev-shell ``repro`` on ``PATH`` cannot stand in for the build
## under test.

include tc8c_store_fixture

proc hookEnv(fx: StoreFixture): seq[tuple[name, value: string]] =
  @[(name: "REPROBUILD_REPRO", value: fx.reproBin),
    (name: "PATH", value: fx.reproBin.parentDir & PathSep & getEnv("PATH"))]

proc ensureHooks(fx: StoreFixture) =
  let res = runArgv(@[fx.reproBin, "hooks", "ensure", "--vcs", fx.libAPath],
    fx.libAPath, fx.hookEnv)
  if res.code != 0:
    checkpoint("hooks ensure failed: " & res.output)
  doAssert res.code == 0, res.output

proc git(fx: StoreFixture; args: varargs[string]):
    tuple[code: int; output: string] =
  ## A real git command in the developer clone, with the hook environment.
  var argv = @["git", "-C", fx.libAPath]
  for a in args: argv.add(a)
  runArgv(argv, fx.libAPath, fx.hookEnv)

proc mustGit(fx: StoreFixture; args: varargs[string]): string =
  var argv: seq[string]
  for a in args: argv.add(a)
  let res = fx.git(argv)
  if res.code != 0:
    checkpoint("git " & argv.join(" ") & " failed:\n" & res.output)
  doAssert res.code == 0, "git " & argv.join(" ") & ": " & res.output
  res.output

proc head(fx: StoreFixture): string = gitOut(fx.libAPath, "rev-parse", "HEAD")

proc indexPath(fx: StoreFixture): string = fx.libAPath / ".git" / "index"

proc indexContentId(fx: StoreFixture): string =
  ## The content id of the staged index, by git alone, over a COPY of the
  ## index (``write-tree`` stores a cache-tree back into the index it reads,
  ## and the tests assert the real index is never written).
  let scratch = createTempDir("tc8g-index-", "")
  defer: removeDir(scratch)
  let copy = scratch / "index"
  copyFile(fx.indexPath, copy)
  let tree = runShell(shellCommand(@["git", "-C", fx.libAPath, "write-tree"],
    @[(name: "GIT_INDEX_FILE", value: copy)]))
  doAssert tree.code == 0, tree.output
  "git-tree-sha1:" & tree.output.strip()

proc treeWith(fx: StoreFixture; files: openArray[(string, string)]): string =
  ## The content id of HEAD's tree with ``files`` (path, body) replaced: the
  ## content a ``git commit <paths>`` of exactly those files records. Built in
  ## a scratch index, never the repository's.
  let scratch = createTempDir("tc8g-tree-", "")
  defer: removeDir(scratch)
  let env = @[(name: "GIT_INDEX_FILE", value: scratch / "index")]
  doAssert runShell(shellCommand(@["git", "-C", fx.libAPath, "read-tree",
    "HEAD"], env)).code == 0
  for (path, body) in files:
    let blobFile = scratch / "blob"
    writeFile(blobFile, body)
    let blob = runShell(shellCommand(@["git", "-C", fx.libAPath,
      "hash-object", "-w", blobFile]))
    doAssert blob.code == 0, blob.output
    let added = runShell(shellCommand(@["git", "-C", fx.libAPath,
      "update-index", "--add", "--cacheinfo",
      "100644," & blob.output.strip() & "," & path], env))
    doAssert added.code == 0, added.output
  let tree = runShell(shellCommand(@["git", "-C", fx.libAPath, "write-tree"],
    env))
  doAssert tree.code == 0, tree.output
  "git-tree-sha1:" & tree.output.strip()

proc certify(fx: StoreFixture; content: string) =
  ## A registered-signed certificate for ``content`` in the user root of the
  ## local store, where every conforming producer delivers.
  let published = publishCertificateToLocalStore(
    signedCertFor(fx, content, fx.head), fx.libAPath)
  doAssert published.written, published.error

proc gateLog(fx: StoreFixture): string =
  let path = preCommitLogPath(fx.workspaceRoot)
  if fileExists(path): readFile(path) else: ""

proc gateLogLines(fx: StoreFixture; marker: string): int =
  for line in fx.gateLog.splitLines():
    if ("certificate-gate " & marker) in line:
      inc result

proc commit(fx: StoreFixture; args: varargs[string]):
    tuple[code: int; output: string] =
  var argv = @["commit"]
  for a in args: argv.add(a)
  fx.git(argv)
