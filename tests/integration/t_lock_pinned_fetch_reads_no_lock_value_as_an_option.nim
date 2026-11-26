## A lock-pinned producer is fetched with the url and the revision its lock
## row records (Cross-Repo-Source-Consumption SC-6, ``fetchLockPinnedProducer``;
## the `--locked` build's ``materializeLockedRevision`` falls back to it). A
## committed lock is a teammate's commit, so neither value may reach git as an
## option: `git fetch <repo> --upload-pack=<cmd>` runs `<cmd>`, because git
## parses options after the repository argument.
##
## Falsifying mutation: dropping `--end-of-options` from the fetch lets the
## `--upload-pack` revision run its command, which creates the marker file.
##
## No mock: real git repositories and the production fetch.

import std/[os, osproc, tempfiles, unittest]

import repro_lock
import repro_cli_support

proc git(args: openArray[string]) =
  var cmd = "git"
  for a in args: cmd.add " " & quoteShell(a)
  let r = execCmdEx(cmd)
  doAssert r.exitCode == 0, cmd & ": " & r.output

suite "a lock-pinned producer fetch reads no lock value as an option":
  test "an --upload-pack revision or url runs nothing":
    let root = createTempDir("lock-pinned-fetch-", "")
    defer: removeDir(root)
    let origin = root / "origin"
    git(["init", "-q", origin])
    git(["-C", origin, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
      "commit", "-q", "--allow-empty", "-m", "x"])
    let marker = root / "ran-upload-pack"
    let injected = "--upload-pack=touch " & quoteShell(marker) &
      "; git-upload-pack"
    let ws = root / "ws"
    createDir(ws)
    for (url, revision) in [(origin, injected),
        (injected, "0123456789abcdef0123456789abcdef01234567")]:
      let dep = LockedDep(name: "lib", coordinates: Coordinates(kind: ckVcs,
        url: url, revision: revision))
      var refused = ""
      try:
        discard fetchLockPinnedProducer(dep, ws)
      except CatchableError as e:
        refused = e.msg
      checkpoint refused
      check refused.len > 0
      check not fileExists(marker)
