## Gate: `e2e_home_get_returns_the_effective_value`.
##
## `repro home get <pkg>.<key>` prints the value the planner resolves on this
## host. When several assignments of one key apply here -- the
## default-plus-override idiom: an unguarded value, then a value under a
## runtime `when <pred>:` guard, or a second package block inside a guard
## chain -- scalars resolve last-write-wins
## (Configurable-System.md §Priorities And Contributions), so `get` must
## print the LAST applicable assignment, and say on stderr which earlier
## assignments it overrides (the spec's "structured diagnostic listing both
## sites"). It used to print the FIRST one, disagreeing with the
## effective-config resolver `repro home set` pre-validates with.
##
## Both now call `effectiveConfigAssignments`; the order it resolves in is
## the compiled profile's `configOverrides` order, which
## `tests/e2e/m83/t_e2e_home_set_writes_guarded_config.nim` gates against a
## real compile. This gate needs no compile (`get` reads the profile text
## when no generation has been applied), so it runs on every platform: the
## guards are `host() == "..."` predicates over `$REPRO_HOST`, which hold or
## fail the same way on Linux, macOS and Windows.
##
## No mocks: the real `build/bin/repro`, a real profile file, an isolated
## HOME / profile / state / store. Nothing is applied.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

const ProjectRoot = currentSourcePath().parentDir().parentDir().
  parentDir().parentDir()
const Host = "gm3-get-host"

# Line numbers matter: the diagnostic names them (line 1 is `import`).
const Profile = """
import repro_profile

profile "gm3Get":
  activity default:
    git

  config:
    git:
      userName = "first"
      editor = "nano"
      when host() == "gm3-get-host":
        userName = "second"
    when host() == "gm3-get-host":
      git:
        editor = "vim"
    when host() == "some-other-host":
      git:
        editor = "notepad"

  hosts:
    "gm3-get-host": []
"""

proc reproBinary(): string =
  result = ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc runGet(root, key: string):
    tuple[exitCode: int; stdout, stderr: string] =
  ## `repro home get <key>` in an isolated environment, stdout and stderr
  ## captured separately (the value is stdout; the note is stderr). Both
  ## are a few lines, so reading one pipe to the end before the other
  ## cannot block on a full pipe.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["HOME"] = root / "home"
  env["USERPROFILE"] = root / "home"
  env["REPRO_HOME_PROFILE_DIR"] = root / "profile"
  env["REPRO_HOME_STATE_DIR"] = root / "state"
  env["REPRO_STORE_ROOT"] = root / "store"
  env["REPRO_HOST"] = Host
  let p = startProcess(reproBinary(), args = @["home", "get", key],
    env = env, options = {})
  result.stdout = p.outputStream().readAll()
  result.stderr = p.errorStream().readAll()
  result.exitCode = p.waitForExit()
  p.close()

suite "repro home get: the effective value":

  test "e2e_home_get_returns_the_effective_value":
    let root = createTempDir("repro-gm3-get-", "")
    defer: removeDir(root)
    for d in ["home", "profile", "state", "store"]:
      createDir(root / d)
    writeFile(root / "profile" / "home.nim", Profile)

    let userName = runGet(root, "git.userName")
    checkpoint("get git.userName stderr:\n" & userName.stderr)
    check userName.exitCode == 0
    check userName.stdout.strip() == "second"
    # The override names what it overrides.
    check "git.userName is assigned 2 times on this host" in userName.stderr
    check "the last assignment (home.nim:12) wins over home.nim:9" in
      userName.stderr

    # Across package blocks: the guarded `git:` block's value wins over the
    # unguarded block's, and the other host's block does not apply.
    let editor = runGet(root, "git.editor")
    checkpoint("get git.editor stderr:\n" & editor.stderr)
    check editor.exitCode == 0
    check editor.stdout.strip() == "vim"
    check "the last assignment (home.nim:15) wins over home.nim:10" in
      editor.stderr
    check "home.nim:18" notin editor.stderr

    # A key assigned once prints no note.
    writeFile(root / "profile" / "home.nim",
      Profile.replace("        userName = \"second\"\n", "        pager = \"less\"\n"))
    let single = runGet(root, "git.userName")
    check single.exitCode == 0
    check single.stdout.strip() == "first"
    check "assigned" notin single.stderr
