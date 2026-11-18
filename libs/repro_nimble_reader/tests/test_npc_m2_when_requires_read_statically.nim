## NPC-M2 `test_npc_m2_when_requires_read_statically`: the documented
## platform-dependent form
##
##   when defined(macosx):
##     requires "libcurl >= 1.0.0"
##
## yields exactly one requirement entry carrying the typed platform condition
## `defined(macosx)`, read by the static reader and not by a NimScript run.
## Nimble's own declarative parser cannot read a `requires` inside `when`
## (it routes such a file to the VM); this reader does, within the closed
## condition set.
##
## "No VM run" is checked the only way it can fail observably: the file also
## carries a top-level statement that writes a canary file whenever the file
## is evaluated, and the canary must not exist after the read.

import std/[os, unittest]

import repro_nimble_reader
import repro_test_support/process_fixtures

suite "npc-m2 when requires read statically":
  test "test_npc_m2_when_requires_read_statically":
    let dir = getTempDir() / ("npc_m2_when_" & $getCurrentProcessId())
    releaseDirAtProcessExit(dir)
    createDir(dir)
    let canary = dir / "evaluated.canary"
    writeFile(dir / "curlwrap.nimble",
      "version = \"0.1.0\"\n" &
      "writeFile(\"" & canary & "\", \"the file was evaluated\")\n" &
      "\n" &
      "when defined(macosx):\n" &
      "  requires \"libcurl >= 1.0.0\"\n")
    let reading = readPackageDir(dir)
    require reading.kind == prRead
    let f = reading.file
    check not fileExists(canary)
    check f.readerClass == rcClosedWhen
    check f.isStaticallyReadable
    check flUnreadable notin f.flags
    require f.requires.len == 1
    let entry = f.requires[0]
    check entry.condition == definedOs("macosx")
    check $entry.condition == "defined(macosx)"
    check entry.requirement.target.kind == tkPackage
    check entry.requirement.target.name == "libcurl"
    check entry.requirement.version.kind == vkRange
    check entry.requirement.version.normalized == ">= 1.0.0"
    # The solver decides the condition per platform; the record holds both.
    check entry.condition.evaluate("macosx", "arm64", "macosx", "arm64")
    check not entry.condition.evaluate("linux", "amd64", "linux", "amd64")
    check f.undecided.len == 0

  test "an elif and an else branch carry the negation of earlier conditions":
    let f = readNimbleSource(
      "when defined(windows):\n" &
      "  requires \"winim >= 3.0\"\n" &
      "elif hostOS == \"linux\" or defined(freebsd):\n" &
      "  requires \"posixstuff\"\n" &
      "else:\n" &
      "  requires \"fallback#head\"\n", "branches.nimble")
    check f.readerClass == rcClosedWhen
    require f.requires.len == 3
    check $f.requires[0].condition == "defined(windows)"
    check $f.requires[1].condition ==
      "(not (defined(windows)) and (hostOS == \"linux\" or defined(freebsd)))"
    check $f.requires[2].condition ==
      "(not (defined(windows)) and not ((hostOS == \"linux\" or defined(freebsd))))"
    check f.requires[2].requirement.version.kind == vkHead
    check f.requires[0].condition.evaluate("windows", "amd64", "linux", "amd64")
    check not f.requires[2].condition.evaluate("windows", "amd64", "linux", "amd64")
    check f.requires[2].condition.evaluate("macosx", "arm64", "macosx", "arm64")

  test "an inline when and a nested when compose their conditions":
    let f = readNimbleSource(
      "when defined(linux): requires \"a\"\n" &
      "when not defined(js):\n" &
      "  when defined(arm64):\n" &
      "    requires \"b >= 1.0 & < 2.0\"\n", "nested.nimble")
    check f.readerClass == rcClosedWhen
    require f.requires.len == 2
    check $f.requires[0].condition == "defined(linux)"
    check $f.requires[1].condition == "(not (defined(js)) and defined(arm64))"
    check f.requires[1].requirement.version.normalized == ">= 1.0.0, < 2.0.0"

  test "defined(<os>) holds on the targets Nim defines it for":
    # Nim's `isDefined` also answers `linux` on Android, `macosx` on iOS and
    # `freebsd` on CROSSOS; `hostOS` is the target's own name only. A
    # requirement under `when defined(linux):` therefore applies to an
    # Android target too.
    let f = readNimbleSource(
      "when defined(linux):\n  requires \"a\"\n" &
      "when defined(macosx):\n  requires \"b\"\n" &
      "when defined(freebsd):\n  requires \"c\"\n" &
      "when hostOS == \"linux\":\n  requires \"d\"\n", "aliases.nimble")
    require f.requires.len == 4
    let (linux, macosx, freebsd, hostLinux) = (f.requires[0].condition,
      f.requires[1].condition, f.requires[2].condition, f.requires[3].condition)
    check linux.evaluate("linux", "amd64", "linux", "amd64")
    check linux.evaluate("android", "arm64", "linux", "amd64")
    check not linux.evaluate("macosx", "arm64", "macosx", "arm64")
    check macosx.evaluate("macosx", "arm64", "macosx", "arm64")
    check macosx.evaluate("ios", "arm64", "macosx", "arm64")
    check not macosx.evaluate("linux", "amd64", "linux", "amd64")
    check freebsd.evaluate("freebsd", "amd64", "freebsd", "amd64")
    check freebsd.evaluate("crossos", "amd64", "linux", "amd64")
    check not freebsd.evaluate("openbsd", "amd64", "openbsd", "amd64")
    check hostLinux.evaluate("android", "arm64", "linux", "amd64")
    check not hostLinux.evaluate("linux", "amd64", "android", "arm64")
    # `not defined(linux)` is false on Android as well.
    check not negate(linux).evaluate("android", "arm64", "linux", "amd64")
