## M69 — `repro home add <tool>@<version>` writes the versioned line.
##
## The structural editor's `addPackageReference` (the proc the CLI's
## `runHomeAdd` calls under the hood) MUST:
##
##   1. Write `package(<tool>, "<version>")` when called with a
##      non-empty `version` argument (the spec's literal form);
##   2. Leave bare references untouched when removing a versioned
##      reference (`repro home remove jdk@21.0.5` strips ONLY the
##      pinned line);
##   3. Preserve comments, blank lines, and the trailing newline
##      across the round-trip.

import std/[os, strutils, unittest]
import repro_home_intent

const TmpDir = "build/test-tmp/m69-home-add-versioned"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc seed(name, src: string): string =
  ## Write a fixture profile under TmpDir and return its absolute path.
  let path = TmpDir / name
  writeFile(path, src)
  path

suite "M69 repro home add <tool>@<version>":

  test "add jdk@21.0.5 writes `package(jdk, \"21.0.5\")` into the activity":
    resetTmp()
    let src = """import repro/profile

profile "rt":
  activity dev:
    git
"""
    let path = seed("home.nim", src)
    addPackageReference(path, "jdk", activity = "dev",
      version = "21.0.5")
    let written = readFile(path)
    check "package(jdk, \"21.0.5\")" in written
    # The pre-existing bare `git` line MUST survive untouched.
    check "    git\n" in written or "    git\r\n" in written

  test "add jdk@21.0.5 then remove jdk@21.0.5 round-trips byte-identically":
    resetTmp()
    let src = """import repro/profile

profile "rt":
  activity dev:
    git
"""
    let path = seed("home.nim", src)
    addPackageReference(path, "jdk", activity = "dev",
      version = "21.0.5")
    let afterAdd = readFile(path)
    check "package(jdk, \"21.0.5\")" in afterAdd
    removePackageReference(path, "jdk", activity = "dev",
      version = "21.0.5")
    let afterRemove = readFile(path)
    check afterRemove == src

  test "remove jdk@21.0.5 strips ONLY the pinned line; bare `package(jdk)` survives":
    resetTmp()
    let src = """import repro/profile

profile "rt":
  activity dev:
    git
    package(jdk)
    package(jdk, "21.0.5")
"""
    let path = seed("home.nim", src)
    removePackageReference(path, "jdk", activity = "dev",
      version = "21.0.5")
    let after = readFile(path)
    # The pinned line must be gone.
    check "package(jdk, \"21.0.5\")" notin after
    # The bare reference must survive.
    check "package(jdk)" in after

  test "remove jdk (no version) strips a matching ref regardless of pin":
    resetTmp()
    let src = """import repro/profile

profile "rt":
  activity dev:
    package(jdk, "21.0.5")
"""
    let path = seed("home.nim", src)
    removePackageReference(path, "jdk", activity = "dev")
    let after = readFile(path)
    check "package(jdk" notin after

  test "add jdk@21.0.5 alongside bare git produces a parseable profile":
    resetTmp()
    let src = """import repro/profile

profile "rt":
  activity dev:
    git
"""
    let path = seed("home.nim", src)
    addPackageReference(path, "jdk", activity = "dev",
      version = "21.0.5")
    addPackageReference(path, "maven", activity = "dev",
      version = "3.9.16")
    addPackageReference(path, "node", activity = "dev")
    # Round-trip the resulting file through the parser; every line
    # must classify correctly.
    let parsed = loadProfile(path)
    let act = parsed.root.children[0]
    check act.kind == nkActivity
    check act.activityName == "dev"
    var pkgsByName: seq[(string, string)]
    for ch in act.activityChildren:
      if ch.kind == nkPackageRef:
        pkgsByName.add((ch.packageName, ch.packageVersion))
    check pkgsByName.len == 4
    check ("git", "") in pkgsByName
    check ("jdk", "21.0.5") in pkgsByName
    check ("maven", "3.9.16") in pkgsByName
    check ("node", "") in pkgsByName
