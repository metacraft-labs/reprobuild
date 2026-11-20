## NPC-M4 verification `test_npc_generator_deterministic_two_hosts`: two
## hosts generating from the same source set and registry commit, against
## the same origin answers, produce the same root hash (NPC-AREQ9, spec
## § 18, threat model G9).
##
## The two "hosts" are two generations in this process that share nothing
## but the served origins: each has its own state directory (the engine
## cache and edge outputs) under its own temporary root, its own working
## directory, `HOME`, `TZ`, locale and unrelated environment variables, and
## its own spelling of the source set (tables in another order, other
## comments and spacing). They run at least a second apart, so a clock read
## into an output differs between them. The origins are local git
## repositories served over real HTTPS and do not change between the runs:
## the "recorded origin answers".

import std/[os, strutils, tempfiles, unittest]

import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

proc setupOrigins(f: Fixture): tuple[registryUrl, registryCommit: string] =
  let alpha = f.newRepo("nim/alpha.git")
  discard alpha.commit(@[nimbleFile("alpha", @["beta >= 1.0.0"]),
    file("src/alpha.nim", "proc a*() = discard\n")])
  alpha.tag("v1.0.0")
  discard alpha.commit(@[nimbleFile("alpha", @["beta >= 1.1.0", "nim >= 2.0.0"]),
    file("src/alpha.nim", "proc a*() = discard\n"),
    file("src/alpha/util.nim", "discard\n")], date = 1_700_100_000)
  alpha.annotatedTag("v1.1.0")
  alpha.publish()
  let beta = f.newRepo("nim/beta.git")
  discard beta.commit(@[nimbleFile("beta"), file("src/beta.nim", "discard\n")])
  beta.tag("1.0.0")
  beta.tag("latest")
  discard beta.commit(@[nimbleFile("beta", @["gamma"]),
    file("src/beta.nim", "discard\n")], date = 1_700_200_000)
  beta.tag("1.1.0")
  beta.publish()
  let gamma = f.newRepo("nim/gamma.git")
  discard gamma.commit(@[nimbleFile("gamma", extra = "task test, \"t\":\n  exec \"true\"\n"),
    file("src/gamma.nim", "discard\n")])
  gamma.tag("0.1.0")
  gamma.publish()
  let reg = f.newRepo("nim-lang/packages.git")
  result.registryCommit = reg.commit(@[packagesJson(@[
    ("alpha", f.url("nim/alpha.git")), ("beta", f.url("nim/beta.git")),
    ("gamma", f.url("nim/gamma.git"))], @[("Gamma_Old", "gamma")])])
  reg.publish()
  result.registryUrl = f.url("nim-lang/packages.git")

proc hostA(regUrl, regCommit, extraUrl: string): string =
  sourceSetText(regUrl, regCommit, """
[[extra]]
name = "delta"
origin = "$1"

[[extra]]
name = "epsilon"
origin = "$1"

[policy]
cooldown_days = 0
track_head = ["beta", "alpha"]
""" % [extraUrl])

proc hostB(regUrl, regCommit, extraUrl, mirror: string): string =
  # The same content: tables in another order, other comments and spacing,
  # and its own mirror: where the sources are kept is not identity.
  "# host B's copy of the source set\n" &
    "schema = \"reprobuild.nimble-source-set.v1\"\n\n" &
    "[[mirror]]\nurl = \"" & mirror & "\"\n\n" &
    "[policy]\ntrack_head = [\"alpha\",\"beta\"]   # sorted otherwise\n" &
    "cooldown_days = 0\n\n" &
    "[[extra]]\norigin = \"" & extraUrl & "\"\nname = \"epsilon\"\n\n" &
    "[[extra]]\n  name   =   \"delta\"\n  origin = \"" & extraUrl & "\"\n\n" &
    "[[registry]]\ncommit = \"" & regCommit & "\"\nremote = \"" & regUrl &
    "\"\n"

type HostEnv = object
  home, tz, lang, cwd: string
  noise: seq[(string, string)]

proc asHost(h: HostEnv; body: proc()) =
  let saved = @[("HOME", getEnv("HOME")), ("TZ", getEnv("TZ")),
                ("LANG", getEnv("LANG")), ("LC_ALL", getEnv("LC_ALL"))]
  let savedCwd = getCurrentDir()
  createDir(h.home)
  createDir(h.cwd)
  putEnv("HOME", h.home)
  putEnv("TZ", h.tz)
  putEnv("LANG", h.lang)
  putEnv("LC_ALL", h.lang)
  for (k, v) in h.noise: putEnv(k, v)
  setCurrentDir(h.cwd)
  try:
    body()
  finally:
    setCurrentDir(savedCwd)
    for (k, v) in saved:
      if v.len > 0: putEnv(k, v) else: delEnv(k)
    for (k, _) in h.noise: delEnv(k)

suite "NPC-M4: two hosts generate the same root":

  test "same source set, registry commit and origin answers: same root":
    let f = newFixture("two-hosts")
    let (regUrl, regCommit) = setupOrigins(f)
    let delta = f.newRepo("nim/delta.git")
    discard delta.commit(@[nimbleFile("delta", @["alpha#head"]),
      file("src/delta.nim", "discard\n")])
    delta.tag("v0.1")
    delta.publish()
    let extraUrl = f.url("nim/delta.git")
    let generatedAt = 1_790_000_000'u64

    var a, b: GenerationResult
    let hostRootA = createTempDir("npc-m4-hostA-", "")
    let hostRootB = createTempDir("npc-m4-hostB-", "")
    asHost(HostEnv(home: hostRootA / "home", tz: "UTC", lang: "C",
        cwd: hostRootA / "cwd", noise: @[("NPC_HOST", "a")])) do ():
      let ss = parseSourceSet(hostA(regUrl, regCommit, extraUrl), "a.toml")
      a = generate(f.genConfig(ss, generatedAt, hostRootA / "state",
        outputDir = hostRootA / "published-index"))
    sleep(1100)
    asHost(HostEnv(home: hostRootB / "home", tz: "Pacific/Kiritimati",
        lang: "de_DE.UTF-8", cwd: hostRootB / "elsewhere" / "cwd",
        noise: @[("NPC_HOST", "b"), ("SOURCE_DATE_EPOCH", "1"),
                 ("GIT_DIR", hostRootB / "not-a-repo")])) do ():
      let ss = parseSourceSet(hostB(regUrl, regCommit, extraUrl, hostRootB / "mirror"), "b.toml")
      b = generate(f.genConfig(ss, generatedAt, hostRootB / "state",
        outputDir = hostRootB / "published-index"))

    check a.built.rootId == b.built.rootId
    check a.built.objects == b.built.objects
    # The written index directories are byte-identical too.
    for (id, bytes) in a.built.objects:
      check readFile(hostRootB / "published-index" / "objects" / $id) ==
        readFile(hostRootA / "published-index" / "objects" / $id)
    check readFile(hostRootA / "published-index" / "root") ==
      readFile(hostRootB / "published-index" / "root")
    # Positive control: the index is not trivially empty.
    check a.built.root.packageCount == 5
    check a.built.hasPackage("alpha")
    check a.built.envelopeOf("alpha").versions.len == 3 # two tags and HEAD
    check a.built.envelopeOf("beta").versions.len == 4  # 1.0.0, latest, 1.1.0, HEAD
    check a.built.hasPackage("Gamma_Old")               # an alias
    for v in a.built.envelopeOf("alpha").versions:
      check v.firstSeen == generatedAt
    # The comparison is sensitive: a different generation time is a
    # different root.
    let hostRootC = createTempDir("npc-m4-hostC-", "")
    let c = generate(f.genConfig(parseSourceSet(hostA(regUrl, regCommit,
      extraUrl), "a.toml"), generatedAt + 1, hostRootC / "state"))
    check c.built.rootId != a.built.rootId
    # And `repro catalog verify` agrees: a third run from host A's published
    # index and the same inputs reproduces the root.
    let v = verifyIndex(hostRootA / "published-index",
      parseSourceSet(hostB(regUrl, regCommit, extraUrl, hostRootB / "mirror"), "b.toml"), "",
      hostRootC / "verify-state", f.genConfig(SourceSet(), 0, ""))
    check v.verified
    check v.differences.len == 0
