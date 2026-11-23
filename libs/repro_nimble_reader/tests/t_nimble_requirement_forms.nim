## Nimble requirement strings and their translation into the solver's range
## grammar, form by form.
##
## The `^=` / `~=` cases beyond the seven documented examples, and the
## accept / reject cases, were checked against Nimble 0.20.1's own
## `version.parseRequires` (tag `v0.20.1`, compiled and run on each string):
## the expected bounds below are the ones Nimble computes, padded to three
## components.

import std/[options, strutils, unittest]

import repro_solver/version_constraints
import repro_solver/nimble_versions
import repro_nimble_reader

proc one(s: string): Requirement =
  let r = readRequirements(s)
  doAssert r.errors.len == 0, s & ": " & $r.errors
  doAssert r.requirements.len == 1, s
  r.requirements[0]

proc normalized(s: string): string = one(s).version.normalized

proc errorOf(s: string): RequirementError =
  let r = readRequirements(s)
  doAssert r.errors.len == 1, s & " should be refused"
  r.errors[0]

suite "nimble requirement forms":
  test "plain operators pad to three components":
    check normalized("a >= 1.2") == ">= 1.2.0"
    check normalized("a > 1") == "> 1.0.0"
    check normalized("a < 2.0.1") == "< 2.0.1"
    check normalized("a <= 0.3") == "<= 0.3.0"
    check normalized("a == 1.4.0") == "== 1.4.0"
    check normalized("a 1.4") == "== 1.4.0"
    check normalized("a >=1.0") == ">= 1.0.0"
    check normalized("a  >=  1.0") == ">= 1.0.0"
    check normalized("a >= 00.1") == ">= 0.1.0"

  test "an intersection becomes a comma-separated conjunction":
    check normalized("a >= 1.0 & < 2.0") == ">= 1.0.0, < 2.0.0"
    check normalized("a >= 1.0&<2.0") == ">= 1.0.0, < 2.0.0"
    check normalized("a <= 1.0 & >= 0.5") == "<= 1.0.0, >= 0.5.0"
    check normalized("a ^= 1.2 & < 1.5") == ">= 1.2.0, < 2.0.0, < 1.5.0"
    let r = one("a >= 1.0 & < 2.0").version.range
    check r == parseSemverRange(">=1.0.0 <2.0.0")

  test "caret and tilde beyond the documented examples follow Nimble":
    check normalized("a ^= 0.0.1") == ">= 0.0.1, < 0.0.2"
    check normalized("a ^= 0.1") == ">= 0.1.0, < 0.2.0"
    check normalized("a ^= 0.0") == ">= 0.0.0, < 0.0.1"
    check normalized("a ^= 1.2") == ">= 1.2.0, < 2.0.0"
    check normalized("a ^= 2.2.2") == ">= 2.2.2, < 3.0.0"
    check normalized("a ~= 2") == ">= 2.0.0, < 3.0.0"
    check normalized("a ~= 2.2") == ">= 2.2.0, < 3.0.0"
    check normalized("a ~= 0.2.2") == ">= 0.2.2, < 0.3.0"
    check normalized("a ~=1.2") == ">= 1.2.0, < 2.0.0"
    # Nimble compares a component's text with "0", so "00" is not zero.
    check normalized("a ^= 00.1") == ">= 0.1.0, < 1.0.0"

  test "the solver's own caret and tilde are not used":
    # `~2.1` in the solver's grammar is `< 2.2.0`; Nimble's `~= 2.1` is
    # `< 3.0.0`. The translation spells out both bounds.
    check normalized("a ~= 2.1") == ">= 2.1.0, < 3.0.0"
    check parseSemverRange("~2.1").upper.get == semver(2, 2, 0)

  test "pseudo-versions: head, commits and named refs":
    let head = one("a#head")
    check head.version.kind == vkHead
    check one("a#HEAD").version.kind == vkHead
    let full = one("a#0123456789abcdef0123456789abcdef01234567")
    check full.version.kind == vkCommit
    check not full.version.abbreviated
    let short = one("a#ABC1234")
    check short.version.kind == vkCommit
    check short.version.abbreviated
    check short.version.commit == "abc1234"
    let branch = one("a#devel")
    check branch.version.kind == vkRef
    check branch.version.refName == "devel"
    check one("a#fix/arc-ownership").version.refName == "fix/arc-ownership"

  test "URL requirements, subdirectories and forge aliases":
    let u = one("https://github.com/status-im/nim-stew")
    check u.target.kind == tkUrl
    check u.target.url == "https://github.com/status-im/nim-stew"
    check u.version.kind == vkAny
    let s = one("https://github.com/a/b?subdir=pkg/c >= 1.0")
    check s.target.url == "https://github.com/a/b"
    check s.target.subdir == "pkg/c"
    check s.version.normalized == ">= 1.0.0"
    let c = one("https://github.com/a/b#abcdef0")
    check c.target.url == "https://github.com/a/b"
    check c.version.kind == vkCommit
    let g = one("gh:owner/repo >= 0.2")
    check g.target.kind == tkUrl
    check g.target.url == "https://github.com/owner/repo"
    check g.target.forgeAlias == "gh:owner/repo"
    check one("srht:owner/repo").target.url == "https://git.sr.ht/~owner/repo"
    check one("git@github.com:a/b").target.kind == tkUrl
    check errorOf("https://github.com/a/b?ref=x").kind == reMalformed

  test "a string can hold a comma- or newline-separated list":
    let r = readRequirements("nim >= 1.6, results >= 0.4,\n  stew#head")
    check r.errors.len == 0
    check r.requirements.len == 3
    check r.requirements[2].version.kind == vkHead
    check readRequirements("").requirements.len == 0

  test "features before or after the range, commas inside kept together":
    let a = one("figdraw[siwin, sharedlib] >= 0.35.2")
    check a.target.name == "figdraw"
    check a.features == @["siwin", "sharedlib"]
    check a.version.normalized == ">= 0.35.2"
    let b = one("sigils >= 0.31.0 [closures, chronos]")
    check b.features == @["closures", "chronos"]
    check b.version.normalized == ">= 0.31.0"
    let c = readRequirements("x[f1, f2], y >= 1")
    check c.requirements.len == 2
    check c.requirements[0].features == @["f1", "f2"]
    # A ref stays attached to the name across a feature list.
    let d = one("gh:elcritch/nim-markdown#devel[regex]")
    check d.version.kind == vkRef
    check d.version.refName == "devel"
    check d.features == @["regex"]
    let e = one("markdown[regex]#head")
    check e.target.name == "markdown"
    check e.version.kind == vkHead
    check e.features == @["regex"]
    check errorOf("x[f1").kind == reMalformed
    check errorOf("x[]").kind == reMalformed
    check errorOf("x[a][b]").kind == reMalformed

  test "forms Nimble rejects are malformed and name the input":
    for s in ["a >= 1.0 & < 2.0 & < 3", "a = 1.2", "a => 1.2", "a >= v1.0",
              "a >= 1.0-rc1", "a >= 1. 0", "a #head", "a#", "a>=1.0",
              "nimble:foo", "a >= .5"]:
      checkpoint s
      let e = errorOf(s)
      check e.kind == reMalformed
      check e.input == s
      check e.reason.len > 0

  test "forms Nimble accepts but the solver cannot express are untranslatable":
    for s in ["a >", "a & >= 1", "a >= 1..2", "scrypt.nim >= 1.0"]:
      checkpoint s
      let e = errorOf(s)
      check e.kind == reUntranslatable
      check e.input == s
    # A zero fourth component is the same version to Nimble and is dropped.
    check normalized("a >= 1.2.3.0") == ">= 1.2.3"

  test "versions of more than three components are translated (NPC-AREQ6)":
    # Every component up to the last non-zero one is kept; `^=` and `~=`
    # find their bound as Nimble's `getNextIncompatibleVersion` does.
    check normalized("a >= 1.2.3.4") == ">= 1.2.3.4"
    check normalized("a == 1.89.9.6") == "== 1.89.9.6"
    check normalized("a >= 1.2.3.4.0") == ">= 1.2.3.4"
    check normalized("a ^= 2.1.1.1") == ">= 2.1.1.1, < 3.0.0"
    check normalized("a ~= 0.6.0.3.1") == ">= 0.6.0.3.1, < 0.6.0.4"
    check normalized("a ^= 0.6.0.3.1") == ">= 0.6.0.3.1, < 0.7.0"
    check normalized("a ^= 0.0.3.1") == ">= 0.0.3.1, < 0.0.4"
    # The semver reading of such a range admits nothing; Nimble's reading
    # is the requirement's meaning.
    let r = one("a >= 0.6.0.3.1").version
    check not satisfies(semver(0, 7, 0), r.range)
    check admits(r.nimbleRange, @[0'u64, 7, 0, 8, 0])
    check admits(r.nimbleRange, @[0'u64, 6, 0, 3, 1])
    check not admits(r.nimbleRange, @[0'u64, 6, 0, 3])

  test "names map to the nimble namespace identity":
    check identity("chronicles") == "nimble:chronicles"
    check nameKey("Nim_Serial") == nameKey("nimserial")
    check one("Nim >= 2.0").isNimTarget
    check not one("nimble >= 0.20").isNimTarget
    check $one("jester ~= 0.4") == "nimble:jester >= 0.4.0, < 1.0.0"
    check $one("https://x.org/a/b?subdir=c#head") ==
      "https://x.org/a/b?subdir=c #head"
    check $one("a#abc1234") == "nimble:a #abc1234 (abbreviated)"
    check "[" notin $one("a")
