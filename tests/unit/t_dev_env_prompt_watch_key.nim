## THE PROMPT KEY MUST SEE WHAT THE ACTIVATION OBSERVED.
##
## `issues/2026-09-28-dev-env-prompt-key-ignores-flake-inputs.md` (in
## `reprobuild-pm`): the shell hook asks `computeDevEnvEdgeCacheKey` on every
## prompt whether the active environment is still current, and the key hashed
## the project file, the lock slice, the develop-overrides file and a few
## environment variables -- none of the files a `useFlakeDevShell()` activation
## actually reads. An edit to `flake.nix`, `flake.lock` or an overridden
## sibling's working tree was answered as a no-op on every prompt after it,
## although `Nix-Flake-Coexistence.md` §2b requires re-entry to be decided
## against the OBSERVED manifest.
##
## The fix folds a "prompt watch manifest" into the key: the activation writes
## the paths its introspection edge observed next to its rollback manifest,
## and the prompt-time key folds in the current `lstat` metadata of each of
## them. This file pins that, per kind of change the issue and §2b name:
##
##   * an edit to a watched file (`flake.nix`);
##   * an edit to a watched file outside the project (an override sibling);
##   * a probed path that was ABSENT appearing (§2b's "probe" case);
##   * a file added to an ENUMERATED directory (membership, not existence);
##
## and that the key is stable when none of them happens -- a key that moves on
## every prompt is a re-activation on every prompt, which is the failure the
## fast path exists to prevent. It also pins the two tokens that stand in for
## "no manifest": an absent argument and an unreadable file must not collide
## with each other or with any real manifest.
##
## NO MOCKS. Real files in a real temp directory, the shipped
## `writePromptWatchManifest` / `computeDevEnvEdgeCacheKey`, and the real
## filesystem's own metadata.

import std/[os, strutils, tempfiles, times, unittest]

import repro_dev_env_engine/cache_key
import repro_test_support/reasoned_skip

proc settle() =
  ## Separate two writes in time by more than any filesystem timestamp tick a
  ## test host plausibly has. Linux stamps inodes from the COARSE kernel clock
  ## (one jiffy, up to 10 ms at HZ=100), so two writes inside one tick can
  ## carry identical mtimes. The production key does not depend on this --
  ## size, inode and ctime move too, and the activation's race guard covers
  ## edits near the activation itself -- but a same-size edit is the
  ## strongest case to assert, so give it a fresh tick.
  sleep(30)

suite "dev-env prompt watch key":

  test "the manifest's observed paths decide the prompt key":
    let root = createTempDir("t_dev_env_prompt_watch_key", "")
    defer: removeDir(root)
    let project = root / "proj"
    let sibling = root / "sib"
    let enumerated = sibling / "tree"
    createDir(project)
    createDir(enumerated)
    writeFile(project / "repro.nim", "# project file\n")
    writeFile(project / "flake.nix", "{ PROBE = \"v1\"; }\n")
    writeFile(sibling / "marker.txt", "sibA\n")
    writeFile(enumerated / "a.nix", "a\n")
    let absent = sibling / "not-yet-here.nix"

    let manifest = root / "activation" / "dev-env.prompt-watch"
    writePromptWatchManifest(manifest, [
      PromptWatchEntry(path: project / "flake.nix"),
      PromptWatchEntry(path: sibling / "marker.txt"),
      PromptWatchEntry(path: absent),
      PromptWatchEntry(path: enumerated, enumerated: true)
    ])
    check fileExists(manifest)

    proc key(): string =
      computeDevEnvEdgeCacheKey(project, "default", "", "",
        watchManifestPath = manifest)

    var seen: seq[string]
    proc note(k: string) =
      check k.len == 32
      check k notin seen
      seen.add(k)

    let first = key()
    note(first)
    # Nothing changed: the same key, twice, or every prompt re-activates.
    check key() == first
    check key() == first

    settle()
    writeFile(project / "flake.nix", "{ PROBE = \"v2\"; }\n")   # same size
    note(key())
    check key() == seen[^1]

    settle()
    writeFile(sibling / "marker.txt", "sibB\n")                # same size
    note(key())

    settle()
    writeFile(absent, "appeared\n")
    note(key())

    settle()
    writeFile(enumerated / "b.nix", "b\n")
    note(key())
    check key() == seen[^1]

  test "a directory that was only probed keys on existence, not membership":
    # An ancestor directory the activation merely stat'ed -- `$HOME`, `/tmp`,
    # the project's parent -- changes membership constantly for reasons that
    # have nothing to do with the environment. Keying on its mtime would make
    # every prompt a re-activation. Only an ENUMERATED directory is keyed on
    # membership.
    let root = createTempDir("t_dev_env_prompt_watch_probe", "")
    defer: removeDir(root)
    let project = root / "proj"
    let probed = root / "probed-ancestor"
    createDir(project)
    createDir(probed)
    writeFile(project / "repro.nim", "# project file\n")
    let manifest = root / "dev-env.prompt-watch"
    writePromptWatchManifest(manifest, [PromptWatchEntry(path: probed)])
    let before = computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = manifest)
    settle()
    writeFile(probed / "unrelated-churn", "x\n")
    check computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = manifest) == before
    # Its kind is still keyed: replacing the directory with a file is seen.
    removeDir(probed)
    writeFile(probed, "now a file\n")
    check computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = manifest) != before

  test "a dangling link whose target appears is a change":
    # The link's own `lstat` is byte-identical before and after its target
    # appears, and std/os calls both states `pcLinkToFile`. The action cache
    # tells them apart (`ffkUnresolvedSymlink`), so the prompt key must too.
    when defined(windows):
      skip("creating a symbolic link on Windows needs a privilege or " &
        "Developer Mode, which CI hosts do not grant")
    else:
      let root = createTempDir("t_dev_env_prompt_watch_link", "")
      defer: removeDir(root)
      let project = root / "proj"
      createDir(project)
      writeFile(project / "repro.nim", "# project file\n")
      let link = project / "flake.nix"
      createSymlink(root / "target.nix", link)
      let manifest = root / "dev-env.prompt-watch"
      writePromptWatchManifest(manifest, [PromptWatchEntry(path: link)])
      let dangling = computeDevEnvEdgeCacheKey(project, "default", "", "",
        watchManifestPath = manifest)
      writeFile(root / "target.nix", "{ }\n")
      check computeDevEnvEdgeCacheKey(project, "default", "", "",
        watchManifestPath = manifest) != dangling

  test "no manifest, a missing manifest and a malformed one are all distinct":
    let root = createTempDir("t_dev_env_prompt_watch_missing", "")
    defer: removeDir(root)
    let project = root / "proj"
    createDir(project)
    writeFile(project / "repro.nim", "# project file\n")
    let present = root / "present.prompt-watch"
    writePromptWatchManifest(present, [])
    let malformed = root / "malformed.prompt-watch"
    writeFile(malformed, "not-a-schema-line\n/some/path\n")
    let missing = root / "missing.prompt-watch"

    let none = computeDevEnvEdgeCacheKey(project, "default", "", "")
    let explicitNone = computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = "")
    let withPresent = computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = present)
    let withMissing = computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = missing)
    let withMalformed = computeDevEnvEdgeCacheKey(project, "default", "", "",
      watchManifestPath = malformed)
    check none == explicitNone
    check none != withPresent
    check none != withMissing
    check none != withMalformed
    check withPresent != withMissing
    check withPresent != withMalformed
    check withMissing != withMalformed

  test "the manifest is located next to the rollback manifest":
    # Both fast paths find it from `$__REPRO_ACTIVE_MANIFEST`, so the writer
    # and every reader must derive the same path from it.
    let rollback = "/x/.repro/dev-env/default/activation-abc" /
      "dev-env.rbde.rollback.json"
    check promptWatchManifestPathFor(rollback) ==
      "/x/.repro/dev-env/default/activation-abc" / "dev-env.prompt-watch"
    check promptWatchManifestPathFor("") == ""

  test "the written manifest is sorted, deduplicated and schema-headed":
    let root = createTempDir("t_dev_env_prompt_watch_format", "")
    defer: removeDir(root)
    let manifest = root / "dev-env.prompt-watch"
    writePromptWatchManifest(manifest, [
      PromptWatchEntry(path: "/b/second"),
      PromptWatchEntry(path: "/a/first"),
      PromptWatchEntry(path: "/b/second"),
      PromptWatchEntry(path: "/a/dir", enumerated: true),
      PromptWatchEntry(path: "/a/dir")
    ])
    let lines = readFile(manifest).strip().splitLines()
    check lines[0] == PromptWatchSchema
    # One line per path; an entry seen both as enumerated and not keeps the
    # stronger (membership) reading.
    check lines.len == 4
    check lines[1].endsWith("/a/dir")
    check lines[1].startsWith("d ")
    check lines[2] == "p /a/first"
    check lines[3] == "p /b/second"

  test "a watched path changed after the activation started is unsettled":
    # The race guard. The activation stats the watch set AFTER its edge ran,
    # so an edit that lands between the edge reading a file and that stat
    # would be keyed as current while the environment was built from the
    # previous content. Such a path must be reported, so the activation can
    # emit a marker no prompt matches.
    let root = createTempDir("t_dev_env_prompt_watch_race", "")
    defer: removeDir(root)
    let early = root / "early.nix"
    let late = root / "late.nix"
    # The absent probe lives in a directory of its own. Beside `late`, its
    # parent would change when `late` appears, and a missing entry whose
    # parent changed is reported as a possible removal (the removal arm,
    # pinned below) -- deliberately conservative, and not what this case is
    # about.
    createDir(root / "quiet")
    let absent = root / "quiet" / "absent.nix"
    writeFile(early, "early\n")
    let manifest = root / "dev-env.prompt-watch"
    writePromptWatchManifest(manifest, [
      PromptWatchEntry(path: early), PromptWatchEntry(path: late),
      PromptWatchEntry(path: absent)])
    # Comfortably past the widest margin the guard allows for coarse
    # filesystem timestamps (two seconds, FAT's resolution).
    sleep(2100)
    let started = epochTime()
    check unsettledPromptWatchPaths(manifest, started).len == 0
    writeFile(late, "late\n")
    check unsettledPromptWatchPaths(manifest, started) == @[late]

  # The race guard's two other kinds of change. Each step below starts its
  # own window (`window()` waits past the widest timestamp margin, then takes
  # the start time), because a directory whose membership moved stays moved
  # for the rest of a window, and one step must not explain or mask another.

  proc window(): float =
    sleep(2100)
    epochTime()

  test "a membership change after the start is unsettled":
    # The MEMBERSHIP arm. An enumerated directory's membership is keyed, so an
    # entry added to it, removed from it or renamed in it between the edge
    # listing it and the activation's stat would be keyed as current while
    # the environment was built from the listing before it. The directory's
    # own timestamps are not the verdict -- the edge moves them itself -- so
    # an entry the edge created, or created and removed again, must not
    # count; everything else must.
    let root = createTempDir("t_dev_env_prompt_watch_membership", "")
    defer: removeDir(root)
    let tree = root / "sibling"
    createDir(tree)
    createDir(root / "elsewhere")
    writeFile(tree / "old.nim", "old\n")
    writeFile(tree / "unread.nim", "unread\n")
    let manifest = root / "dev-env.prompt-watch"
    writePromptWatchManifest(manifest, [
      PromptWatchEntry(path: tree, enumerated: true),
      PromptWatchEntry(path: tree / "old.nim")])
    var started = window()
    check unsettledPromptWatchPaths(manifest, started).len == 0

    # Created by the edge itself, directly and inside a directory it made.
    createDir(tree / "own-dir")
    writeFile(tree / "own-dir" / "inner", "x\n")
    writeFile(tree / "own.txt", "x\n")
    check unsettledPromptWatchPaths(manifest, started,
      ownChanges = [tree / "own-dir" / "inner", tree / "own.txt"]).len == 0
    # Created by anybody else: an addition, reported -- also beside the
    # edge's own entries.
    writeFile(tree / "new.nim", "new\n")
    check unsettledPromptWatchPaths(manifest, started,
      ownChanges = [tree / "own-dir" / "inner", tree / "own.txt"]) == @[tree]

    # Created and removed again by the edge (its scratch): explained.
    started = window()
    writeFile(tree / "scratch.tmp", "x\n")
    removeFile(tree / "scratch.tmp")
    check unsettledPromptWatchPaths(manifest, started,
      ownChanges = [tree / "scratch.tmp"]).len == 0
    # The same by anybody else leaves no entry to tell it from a removal, so
    # it is reported: one extra activation, never a missed removal.
    check unsettledPromptWatchPaths(manifest, started) == @[tree]

    # An entry the edge listed but did not read, removed: nothing current
    # accounts for the move, so it is a removal.
    started = window()
    removeFile(tree / "unread.nim")
    check unsettledPromptWatchPaths(manifest, started) == @[tree]

    # An old file moved in. A rename keeps its mtime, so the entry's ctime
    # (POSIX) or the directory's move (where nothing explains it) reports it.
    started = window()
    writeFile(root / "elsewhere" / "moved.nim", "moved\n")
    started = window()
    moveFile(root / "elsewhere" / "moved.nim", tree / "moved.nim")
    check unsettledPromptWatchPaths(manifest, started) == @[tree]

  test "a listed path removed after the start is unsettled":
    # The REMOVAL arm. A path the edge used and that is then removed is
    # missing at the activation's stat, and so is an absent probe, which the
    # manifest lists too and which is meant to be missing. Removing an entry
    # moves the timestamps of the directory that held it; an absent probe
    # sits below a directory nothing touched. A path the edge removed itself
    # is explained, but only that exact path: a foreign removal in the same
    # directory is still reported.
    let root = createTempDir("t_dev_env_prompt_watch_removed", "")
    defer: removeDir(root)
    let quiet = root / "quiet"
    let busy = root / "busy"
    createDir(quiet)
    createDir(busy)
    createDir(root / "tree" / "sub")
    let absent = quiet / "absent.nix"
    let absentDeep = quiet / "no-such-dir" / "absent.nix"
    let read = busy / "read.nix"
    let ownTemp = busy / "own.tmp"
    let deep = root / "tree" / "sub" / "deep.nix"
    writeFile(read, "read\n")
    writeFile(ownTemp, "tmp\n")
    writeFile(deep, "deep\n")
    let manifest = root / "dev-env.prompt-watch"
    writePromptWatchManifest(manifest, [PromptWatchEntry(path: absent),
      PromptWatchEntry(path: absentDeep), PromptWatchEntry(path: read),
      PromptWatchEntry(path: ownTemp), PromptWatchEntry(path: deep)])
    var started = window()
    check unsettledPromptWatchPaths(manifest, started).len == 0
    # The edge removed its own scratch: explained.
    removeFile(ownTemp)
    check unsettledPromptWatchPaths(manifest, started,
      ownChanges = [ownTemp]).len == 0
    # Somebody else removed a file beside it: reported, although the edge
    # also changed that directory.
    removeFile(read)
    check unsettledPromptWatchPaths(manifest, started,
      ownChanges = [ownTemp]) == @[read]

    # A whole directory removed: the listed file's parent is gone too, and
    # the directory above it moved.
    started = window()
    removeDir(root / "tree" / "sub")
    check unsettledPromptWatchPaths(manifest, started) == @[deep]

    # The conservative side, pinned: an absent probe beside an unrelated
    # change cannot be told from a removal, and is reported -- here and
    # below a directory that does not exist, whose nearest existing ancestor
    # is the one that changed.
    started = window()
    writeFile(quiet / "unrelated", "x\n")
    check unsettledPromptWatchPaths(manifest, started) ==
      @[absent, absentDeep]

  test "a removal below a symbolic link to a directory is unsettled":
    # The directory a removal test reads is stat'ed THROUGH a link: on macOS
    # `/tmp` and `/etc` are links into `/private`, and a link's own
    # timestamps do not move when an entry of its target is removed.
    when defined(windows):
      skip("creating a symbolic link on Windows needs a privilege or " &
        "Developer Mode, which CI hosts do not grant")
    else:
      let root = createTempDir("t_dev_env_prompt_watch_dirlink", "")
      defer: removeDir(root)
      createDir(root / "real")
      let link = root / "link"
      createSymlink(root / "real", link)
      let listed = link / "read.nix"
      writeFile(listed, "read\n")
      let manifest = root / "dev-env.prompt-watch"
      writePromptWatchManifest(manifest, [PromptWatchEntry(path: listed)])
      let started = window()
      check unsettledPromptWatchPaths(manifest, started).len == 0
      removeFile(root / "real" / "read.nix")
      check unsettledPromptWatchPaths(manifest, started) == @[listed]
