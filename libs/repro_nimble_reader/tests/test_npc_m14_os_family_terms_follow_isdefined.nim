## NPC-M14 verification `test_npc_m14_os_family_terms_follow_isdefined`
## (A3; NPC-AREQ7).
##
## `defined(posix)`, `defined(unix)` and `defined(bsd)` are read into the
## closed set as terms of their own, and evaluated for linux, android,
## macosx, ios, freebsd, netbsd, windows and standalone. Each answer equals
## Nim 2.2.4's `isDefined` for that target. The table below is transcribed
## from `compiler/options.nim` of Nim 2.2.4 (tag `v2.2.4` = `f7145dd2`, as
## nixpkgs ships it; `isDefined`, lines 642-651):
##
##   of "posix", "unix":
##     result = conf.target.targetOS in {osLinux, osMorphos, osSkyos, osIrix,
##       osPalmos, osQnx, osAtari, osAix, osHaiku, osVxWorks, osSolaris,
##       osNetbsd, osFreebsd, osOpenbsd, osDragonfly, osMacosx, osIos,
##       osAndroid, osNintendoSwitch, osFreeRTOS, osCrossos, osZephyr, osNuttX}
##   of "bsd":
##     result = conf.target.targetOS in {osNetbsd, osFreebsd, osOpenbsd,
##       osDragonfly, osCrossos}
##
## The expected answers are written out per target here, not taken from the
## evaluator's own sets.
##
## Falsifying mutation (recorded in the plan): deriving `posix` from the OS
## name `linux` alone answers false for macosx, and fails the test.

import std/unittest

import repro_nimble_reader

const
  ## target -> (posix, unix, bsd), per Nim 2.2.4's `isDefined`.
  IsDefined = [
    ("linux", (true, true, false)),
    ("android", (true, true, false)),
    ("macosx", (true, true, false)),
    ("ios", (true, true, false)),
    ("freebsd", (true, true, true)),
    ("netbsd", (true, true, true)),
    ("windows", (false, false, false)),
    ("standalone", (false, false, false))]

proc readOne(cond: string): Condition =
  let f = readNimbleSource("when " & cond & ":\n  requires \"x\"\n",
    "family.nimble")
  doAssert f.readerClass == rcClosedWhen, cond & ": " & $f.readerClass
  doAssert f.requires.len == 1, cond
  f.requires[0].condition

suite "NPC-M14: OS-family terms follow Nim's isDefined":
  test "the three symbols are terms of their own in the closed set":
    for sym in ["posix", "unix", "bsd"]:
      let c = readOne("defined(" & sym & ")")
      check c.kind == ckOsFamily
      check c.name == sym
    # Case- and underscore-insensitive, as `defined` looks symbols up.
    check readOne("defined(Posix)").name == "posix"
    check readOne("defined(u_nix)").name == "unix"

  test "each answer equals isDefined for the target":
    let posix = readOne("defined(posix)")
    let unix = readOne("defined(unix)")
    let bsd = readOne("defined(bsd)")
    for (os, want) in IsDefined:
      checkpoint os
      # The CPU and the host do not matter to an OS-family term.
      check evaluate(posix, os, "amd64", "linux", "amd64") == want[0]
      check evaluate(unix, os, "arm64", "windows", "amd64") == want[1]
      check evaluate(bsd, os, "amd64", "macosx", "arm64") == want[2]

  test "composed with the other terms":
    let c = readOne("defined(posix) and not defined(macosx)")
    check evaluate(c, "linux", "amd64", "linux", "amd64")
    check not evaluate(c, "ios", "arm64", "macosx", "arm64")
    check not evaluate(c, "windows", "amd64", "windows", "amd64")
