## The record-store push guard binds what a push SUPPLIES (CLI/hooks.md, the
## store push guard). Two destination refs that already disagree on one record
## key are a defect of the store's owner, not of an unrelated fast-forward that
## only adds a different record: that push must land, and the disagreement is
## reported as a warning naming both refs and both blob ids.
##
## Still refused: a push that itself supplies bytes differing from what another
## ref publishes for a key it newly adds, and a push that edits a record the
## pushed ref already publishes.
##
## Real `repro` binary, real `git`, a real managed pre-push hook installed by
## `repro hooks ensure --vcs` on a `.repro/records` store checkout, and a local
## bare destination; no mocks, no network.
## Skip rule: `git` missing on PATH.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const
  disputed = "locks/app/lib/b3a0caf.toml"
  fresh = "locks/app/lib/ec67928.toml"

type Fixture = object
  scratch, store, origin, reproBin: string

proc env(fx: Fixture): seq[tuple[name, value: string]] =
  @[(name: "REPROBUILD_REPRO", value: fx.reproBin),
    (name: "XDG_CACHE_HOME", value: fx.scratch / "cache"),
    (name: "PATH", value: fx.reproBin.parentDir & PathSep & getEnv("PATH"))]

proc run(fx: Fixture; args: openArray[string]): CmdResult =
  runShell(shellCommand(args, fx.env), fx.scratch)

proc mustRun(fx: Fixture; args: openArray[string]): string =
  let res = fx.run(args)
  if res.code != 0:
    checkpoint("command failed: " & args.join(" ") & "\n" & res.output)
    raise newException(AssertionDefect, "command failed: " & args.join(" "))
  res.output

proc git(fx: Fixture; args: varargs[string]): string =
  fx.mustRun(@["git", "-C", fx.store] & @args)

proc commitRecord(fx: Fixture; path, body, msg: string) =
  createDir(fx.store / parentDir(path))
  writeFile(fx.store / path, body)
  discard fx.git("add", path)
  discard fx.git("commit", "-q", "--no-verify", "-m", msg)

proc setup(): Fixture =
  result.scratch = createTempDir("repro-store-guard-disagree-", "")
  result.reproBin = reproBinary()
  result.origin = result.scratch / "origin.git"
  result.store = result.scratch / ".repro" / "records"
  createDir(result.scratch / "cache")
  createDir(parentDir(result.store))
  let fx = result
  discard fx.mustRun(["git", "init", "-q", "--bare", "-b", "latest", fx.origin])
  discard fx.mustRun(["git", "init", "-q", "-b", "latest", fx.store])
  discard fx.git("config", "user.email", "tester@example.invalid")
  discard fx.git("config", "user.name", "Tester")
  discard fx.git("remote", "add", "origin", fx.origin)
  # Publish `latest` and `official-deployment` holding different bytes for
  # one key, as the issue's destination did.
  fx.commitRecord(disputed, "rev = \"latest\"\n", "latest record")
  discard fx.git("push", "-q", "--no-verify", "origin", "latest")
  discard fx.git("checkout", "-q", "-b", "official-deployment", "HEAD~0")
  writeFile(fx.store / disputed, "rev = \"official\"\n")
  discard fx.git("commit", "-q", "--no-verify", "-am", "official record")
  discard fx.git("push", "-q", "--no-verify", "origin", "official-deployment")
  discard fx.git("checkout", "-q", "latest")
  discard fx.mustRun([fx.reproBin, "hooks", "ensure", "--vcs", fx.store])

suite "record-store push guard with disagreeing destination refs":
  when defined(posix):
    test "an unrelated addition lands and the disagreement is a warning":
      require findExe("git").len > 0
      let fx = setup()
      defer: removeDir(fx.scratch)
      fx.commitRecord(fresh, "rev = \"new\"\n", "add one record")
      let pushed = fx.run(["git", "-C", fx.store, "push", "origin", "latest"])
      checkpoint(pushed.output)
      check pushed.code == 0
      check "destination refs disagree on published record " & disputed in
        pushed.output
      check "refs/heads/latest holds" in pushed.output
      check "refs/heads/official-deployment holds" in pushed.output
      check fx.git("ls-tree", "-r", "--name-only", "origin/latest").len > 0
      check fx.mustRun(["git", "--git-dir", fx.origin, "cat-file", "-e",
        "latest:" & fresh]) == ""

    test "a push newly supplying different bytes for a published key is refused":
      require findExe("git").len > 0
      let fx = setup()
      defer: removeDir(fx.scratch)
      # `official-deployment` publishes `fresh`; `latest` adds it differently.
      discard fx.git("checkout", "-q", "official-deployment")
      fx.commitRecord(fresh, "rev = \"official-new\"\n", "official adds")
      discard fx.git("push", "-q", "--no-verify", "origin", "official-deployment")
      discard fx.git("checkout", "-q", "latest")
      fx.commitRecord(fresh, "rev = \"latest-new\"\n", "latest adds differently")
      let pushed = fx.run(["git", "-C", fx.store, "push", "origin", "latest"])
      checkpoint(pushed.output)
      check pushed.code != 0
      check "refs/heads/latest changes published record " & fresh in pushed.output

    test "editing a record the pushed ref already publishes is refused":
      require findExe("git").len > 0
      let fx = setup()
      defer: removeDir(fx.scratch)
      fx.commitRecord(disputed, "rev = \"edited\"\n", "edit published record")
      let pushed = fx.run(["git", "-C", fx.store, "push", "origin", "latest"])
      checkpoint(pushed.output)
      check pushed.code != 0
      check "refs/heads/latest changes published record " & disputed in
        pushed.output

    test "two refs of one push supplying different bytes for a key are refused":
      require findExe("git").len > 0
      let fx = setup()
      defer: removeDir(fx.scratch)
      # Both updates are new to the store for `fresh`; neither is on any
      # published snapshot, so only the guard's in-push bookkeeping catches it.
      fx.commitRecord(fresh, "rev = \"one\"\n", "latest adds")
      discard fx.git("checkout", "-q", "-b", "other", "official-deployment")
      fx.commitRecord(fresh, "rev = \"two\"\n", "other adds differently")
      discard fx.git("checkout", "-q", "latest")
      let pushed = fx.run(["git", "-C", fx.store, "push", "origin", "latest", "other"])
      checkpoint(pushed.output)
      check pushed.code != 0
      check "changes published record " & fresh in pushed.output
