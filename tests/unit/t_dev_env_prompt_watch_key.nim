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
    let absent = root / "absent.nix"
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
