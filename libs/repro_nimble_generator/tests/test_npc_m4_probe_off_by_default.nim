## NPC-M4 verification `test_npc_m4_probe_off_by_default` (NPC-AREQ8 step 3,
## threat model G6): with the default source set, no `nimble` process is
## started on any input.
##
## A `nimble` that writes a canary when it runs is first on `PATH`. The
## origins include versions the static reader cannot read (computed
## requirements, a hook, the INI format), which are what a probe would be
## run on. With the default source set the generation reads them as
## needs-probe or needs-override, records them `unreadable`, and starts no
## `nimble`. A source set that turns the probe on is refused: this build has
## no confinement to run it under, and it does not run it without one.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

proc fakeNimble(dir, canary: string) =
  createDir(dir)
  writeFile(dir / "nimble", "#!/bin/sh\necho \"$@\" >> " & canary & "\n")
  setFilePermissions(dir / "nimble", {fpUserRead, fpUserWrite, fpUserExec})

suite "NPC-M4: the probe is off by default":

  test "the default source set starts no nimble process on any input":
    let f = newFixture("probe")
    let bin = f.dir / "bin"
    let canary = f.dir / "nimble-ran"
    fakeNimble(bin, canary)
    putEnv("PATH", bin & ":" & getEnv("PATH"))
    # Positive control: the canary works, so its absence below means
    # something.
    discard run(["nimble", "dump", "--json"])
    check fileExists(canary)
    removeFile(canary)

    let w = f.newRepo("nim/computed.git")
    discard w.commit(@[file("computed.nimble",
      "version = \"1.0\"\nconst deps = [\"a\", \"b\"]\nfor d in deps:\n" &
      "  requires d\n"), file("src/computed.nim", "discard\n")])
    w.tag("v1.0")
    discard w.commit(@[file("computed.nimble",
      "version = \"1.1\"\nrequires gorge(\"echo x\")\n" &
      "before install:\n  exec \"touch /tmp/never\"\n"),
      file("src/computed.nim", "discard\n")])
    w.tag("v1.1")
    discard w.commit(@[file("computed.nimble",
      "[Package]\nname = \"computed\"\nversion = \"1.2\"\n[Deps]\n" &
      "Requires: \"nim >= 1.0\"\n"), file("src/computed.nim", "discard\n")])
    w.tag("v1.2")
    w.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("computed", f.url("nim/computed.git"))])])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let work = createTempDir("npc-m4-probe-run-", "")

    let ss = parseSourceSet(sourceSetText(regUrl, regCommit), "s.toml")
    check ss.policy.probe == ppOff
    let g = generate(f.genConfig(ss, 1_790_000_000, work / "state"))
    check not fileExists(canary)
    let e = g.built.envelopeOf("computed")
    check e.versions.len == 3
    for v in e.versions:
      check flUnreadable in v.flags
      check flUsesProbe notin v.flags
      check v.readerClass in {rrcNeedsProbe, rrcNeedsOverride}

    # Turning the probe on is refused before anything runs.
    let probing = parseSourceSet(sourceSetText(regUrl, regCommit,
      "\n[policy]\nprobe = \"sandboxed\"\n"), "s.toml")
    var refused = ""
    try:
      discard generate(f.genConfig(probing, 1_790_000_000, work / "state2"))
    except GeneratorError as err:
      refused = err.msg
    check "probe = \"sandboxed\" is refused" in refused
    check "NPC-M10" in refused
    check not fileExists(canary)
    check not dirExists(work / "state2")
