## NPC-M2 `test_npc_m2_unrecognised_condition_is_unreadable`: a `requires`
## under a condition outside the closed set (`when fileExists("x"):`) marks
## the version unreadable and is not guessed. The requirement is neither
## offered unconditionally (as if the condition were true) nor dropped (as if
## it were false): the record says it cannot be read statically, keeps what it
## found as written for an override author, and names the condition.
##
## A reader that evaluates unknown conditions as false would return a plain
## record with no requirements — the silent dependency loss this test exists
## to catch.

import std/unittest

import repro_nimble_reader

suite "npc-m2 unrecognised condition is unreadable":
  test "test_npc_m2_unrecognised_condition_is_unreadable":
    let f = readNimbleSource(
      "version = \"1.0.0\"\n" &
      "requires \"nim >= 2.0.0\"\n" &
      "when fileExists(\"x\"):\n" &
      "  requires \"foo\"\n", "guarded.nimble")
    check f.readerClass == rcNeedsOverride
    check not f.isStaticallyReadable
    check flUnreadable in f.flags
    # Not guessed true: the guarded requirement is not an entry.
    check f.requires.len == 0
    # Not guessed false: it is kept, with the condition that guards it.
    require f.undecided.len == 1
    check f.undecided[0].what == "requires"
    check f.undecided[0].text == "foo"
    check f.undecided[0].condition == "fileExists(\"x\")"
    check f.undecided[0].why == ukEnvironment
    var named = false
    for i in f.issues:
      if i.kind == ikConditionOutsideClosedSet and fRequires in i.fields:
        named = true
        check i.detail == "environment: fileExists(\"x\")"
    check named
    # The readable part is still read.
    check f.nim.len == 1

  test "an else after an undecidable condition is undecidable too":
    let f = readNimbleSource(
      "when defined(release):\n" &
      "  requires \"a\"\n" &
      "else:\n" &
      "  requires \"b\"\n", "else.nimble")
    check f.readerClass == rcNeedsOverride
    check f.requires.len == 0
    check f.undecided.len == 2
    check f.undecided[0].why == ukOtherDefine
    check f.undecided[1].why == ukOtherDefine
    check f.undecided[1].condition == "else of defined(release)"

  test "conditions outside the set are named by kind":
    for (cond, why) in [("NimMajor >= 2", ukToolchain),
                        ("(NimMajor, NimMinor) >= (1, 6)", ukToolchain),
                        ("declared(foo)", ukToolchain),
                        ("defined(nimHasSomething)", ukToolchain),
                        ("defined(posix)", ukOsFamily),
                        ("defined(lockfreeChronos)", ukOtherDefine),
                        ("getEnv(\"X\") == \"1\"", ukEnvironment),
                        ("hostOS == \"osx\"", ukUnknownName),
                        ("true", ukLiteral),
                        ("defined(linux) and fileExists(\"y\")",
                            ukEnvironment)]:
      checkpoint cond
      let f = readNimbleSource("when " & cond & ":\n  requires \"x\"\n",
                               "kinds.nimble")
      check f.readerClass == rcNeedsOverride
      check f.requires.len == 0
      require f.undecided.len == 1
      check f.undecided[0].why == why

  test "a guarded field that is not a requirement does not make it unreadable":
    # `foreignDep` and `taskRequires` are not version-record requirements.
    let f = readNimbleSource(
      "requires \"a\"\n" &
      "when defined(nimdistros):\n" &
      "  import distros\n" &
      "  foreignDep \"libcurl\"\n" &
      "when NimMajor >= 2:\n" &
      "  taskRequires \"test\", \"unittest2\"\n", "foreign.nimble")
    check f.readerClass == rcPlain
    check f.requires.len == 1
    check f.foreignDeps.len == 0
    check f.undecided.len == 2
