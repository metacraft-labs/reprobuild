## M2 — end-to-end git history walk regression test.
##
## Guards the two latent Windows-host bugs that surfaced when M2
## was the first end-to-end exercise of ``--version-history N>1``:
##
##   (A) ``runGit`` previously read from the child's stdout pipe via
##       ``startProcess(...).outputStream.readAll()`` BEFORE
##       ``waitForExit``. On Windows that pattern truncates the
##       capture to roughly the first pipe-buffer flush, so a
##       multi-commit ``git log`` returned only the head commit's
##       SHA and ``commitVersionsFor`` accumulated 1 version
##       (silently making ``--version-history N>1`` a no-op).
##   (B) ``git show <sha>:<path>`` insists on forward-slash
##       separators in the rev-spec path component on Windows but
##       ``relativePath`` returns ``bucket\<app>.json`` there;
##       the show invocation returned rc=128 ("invalid object
##       name") for every historical commit so
##       ``commitVersionsFor`` accumulated 0 versions even with
##       (A) fixed.
##
## Both bugs surfaced only when the loop body in
## ``commitVersionsFor`` actually ran across MULTIPLE commits AND
## the harvester was on a Windows host. The M66 in-memory ordering
## test in ``test_harvester_history.nim`` does not exercise
## either path; this test does, via a synthetic ``git init`` repo
## with two commits to the same ``<app>.json`` file. The harvester
## test runs cross-platform — the path-separator fix is a no-op on
## POSIX (``replace('\\', '/')`` on a forward-slash path is the
## identity), and the pipe-drain fix is a correctness improvement
## everywhere.

import std/[json, os, osproc, streams, strutils, tables, unittest]

import ../src/bucket_clone

# ---------------------------------------------------------------------------

proc runGitOrFail(args: openArray[string]; cwd: string) =
  let p = startProcess("git", workingDir = cwd, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  let outp = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0:
    raise newException(IOError,
      "git " & args.join(" ") & " (cwd=" & cwd & ") failed rc=" &
        $rc & ": " & outp)

proc writeManifest(path: string; version: string; url: string) =
  let manifest = %*{
    "version": version,
    "url": url,
    "hash": "sha256:" & repeat('0', 64 - 7) & "deadbe" & "f",
    "extract_dir": "synthetic-" & version,
    "bin": "synthetic.exe",
  }
  writeFile(path, $manifest & "\n")

# ---------------------------------------------------------------------------

suite "M2 — end-to-end git history walk":

  test "two commits to the same manifest yield two (sha, version) pairs":
    # Build a throwaway repo under the OS temp dir. Layout mirrors
    # the Scoop ``bucket/<app>.json`` convention so
    # ``manifestsDirOf`` picks up ``<root>/bucket/`` automatically.
    let tmpRoot = getTempDir() / "repro-harvester-history-walk-test"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot / "bucket")
    let app = "synthetic"
    let manifestPath = tmpRoot / "bucket" / (app & ".json")

    # Init + identity so commit doesn't refuse.
    runGitOrFail(@["init", "--quiet", "--initial-branch=main"], cwd = tmpRoot)
    runGitOrFail(@["config", "user.email", "harvester-test@example.invalid"],
      cwd = tmpRoot)
    runGitOrFail(@["config", "user.name", "Harvester Test"],
      cwd = tmpRoot)
    runGitOrFail(@["config", "commit.gpgsign", "false"], cwd = tmpRoot)

    # Commit 1 — version 0.1.0
    writeManifest(manifestPath, "0.1.0",
      "https://example.test/synthetic-0.1.0.zip")
    runGitOrFail(@["add", "bucket/" & app & ".json"], cwd = tmpRoot)
    runGitOrFail(@["commit", "--quiet", "-m", "synthetic: 0.1.0"],
      cwd = tmpRoot)

    # Commit 2 — version 0.2.0
    writeManifest(manifestPath, "0.2.0",
      "https://example.test/synthetic-0.2.0.zip")
    runGitOrFail(@["add", "bucket/" & app & ".json"], cwd = tmpRoot)
    runGitOrFail(@["commit", "--quiet", "-m", "synthetic: 0.2.0"],
      cwd = tmpRoot)

    # Construct a git-backed BucketRef pointing at the throwaway
    # checkout. ``resolveBucket`` would classify a local path as
    # ``bkLocalDirectory`` (which short-circuits the history walk);
    # we force ``bkGitRepository`` so the walk actually runs — the
    # production code path that comes from ``resolveBucket(spec)``
    # against a Scoop bucket URL hits the same code path.
    let bucket = BucketRef(
      kind: bkGitRepository,
      spec: tmpRoot,
      localRoot: tmpRoot,
      bucketSubdir: "bucket",
    )

    # Bug (A) regression — runGit must drain the full pipe.
    # Bug (B) regression — the rev-spec path must be forward-slashed.
    let versions = commitVersionsFor(bucket, app)

    check versions.len == 2
    # Newest first (git log default).
    check versions[0].version == "0.2.0"
    check versions[1].version == "0.1.0"

    # Bug (B) regression — manifestAtCommit must succeed for the
    # historical commit (NOT just HEAD). If the rev-spec path
    # normalization is dropped, the older commit returns "" and
    # the history walk in harvestApp silently drops it.
    let historicalBody = manifestAtCommit(bucket, app, versions[1].sha)
    check historicalBody.len > 0
    check "\"version\"" in historicalBody
    check "0.1.0" in historicalBody

    # And HEAD-version round-trip too.
    let headBody = manifestAtCommit(bucket, app, versions[0].sha)
    check headBody.len > 0
    check "0.2.0" in headBody

    # Cleanup — best-effort; the OS temp dir is reaped anyway.
    try: removeDir(tmpRoot)
    except: discard

  test "runGit captures output longer than one Windows pipe buffer":
    # Direct regression for Bug (A): synthesize stdout > 8KiB and
    # assert ``runGit`` returns the full payload. Pre-fix, the
    # captured output truncated to roughly the first pipe-buffer
    # flush (~4-8KiB on Windows). We use ``git --version`` looped
    # via ``git log -<N>`` on a synthetic repo to produce enough
    # bytes deterministically across platforms.
    let tmpRoot = getTempDir() / "repro-harvester-pipe-buffer-test"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    runGitOrFail(@["init", "--quiet", "--initial-branch=main"], cwd = tmpRoot)
    runGitOrFail(@["config", "user.email", "harvester-test@example.invalid"],
      cwd = tmpRoot)
    runGitOrFail(@["config", "user.name", "Harvester Test"], cwd = tmpRoot)
    runGitOrFail(@["config", "commit.gpgsign", "false"], cwd = tmpRoot)

    # Produce ~200 commits whose subject lines are ~80 chars each →
    # ~16 KiB of ``git log`` output, comfortably above any single
    # pipe-buffer flush window on Windows.
    let payload = "x".repeat(70)
    writeFile(tmpRoot / "README", "init\n")
    runGitOrFail(@["add", "README"], cwd = tmpRoot)
    runGitOrFail(@["commit", "--quiet", "-m", "init"], cwd = tmpRoot)
    for i in 1 .. 200:
      writeFile(tmpRoot / "README", "rev-" & $i & "\n")
      runGitOrFail(@["add", "README"], cwd = tmpRoot)
      runGitOrFail(@["commit", "--quiet", "--allow-empty-message",
        "-m", "commit-" & $i & "-" & payload], cwd = tmpRoot)

    let (rc, output) = runGit(@["log", "--pretty=format:%H %s"],
      cwd = tmpRoot)
    check rc == 0
    # 201 commits each emitting a >70-byte subject → the captured
    # output is well above one pipe buffer.
    check output.len > 8 * 1024
    # And every commit's subject must be present (would have been
    # truncated mid-stream under the pre-M2 bug).
    check ("commit-1-" & payload) in output
    check ("commit-200-" & payload) in output

    try: removeDir(tmpRoot)
    except: discard
