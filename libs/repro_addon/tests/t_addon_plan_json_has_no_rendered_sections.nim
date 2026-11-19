## ``repro infra|system plan --json`` on an add-on host carries the add-on's
## plan sections as structured keys, not as the text the human form prints
## (CLI-UX-AREQ4; reprobuild-pm spec/CLI/infra/plan.md §JSON output).
##
## Before this rule the add-on branch of ``runInfraPlan`` put every section
## but the ledger diff and the drift under one string, ``addOn.report``: the
## defect recorded in reprobuild-pm
## ``issues/2026-11-17-addon-host-plan-json-carries-text-sections.md``.
## ``runInfraPlan`` builds ``addOn`` with ``addonSectionsJson`` alone (the
## last case holds its add-on branch to that), so the test holds that proc
## to the documented keys.
##
## No mocks. One substitution: the first case runs the real plan path
## (``runAddonApply`` with ``planOnly``) over a fixture dpkg database,
## answering ``systemctl show`` with "not-found" because the build host has
## no guest systemd -- the same substitution ``t_addon_ledger_and_plan``
## makes. The second case fills
## the sections a fixture plan cannot reach (transitions, the base, the
## floor lists, sysctl observations) in a real ``AddonApplyResult`` and
## checks each comes out as the record the text form prints, field by
## field. ``runInfraPlan`` itself is not driven: its add-on branch runs
## ``runAddonApply`` with no driver override, so it reads the host's own
## dpkg database and systemd. The VM gates (``tests/e2e/addon``) drive the
## command on a bootstrapped add-on host.

import std/[json, options, os, strutils, tempfiles, unittest]

import repro_addon/[addon_apply, base_identity, cli, collision, ledger,
                    transitions]

const DocumentedKeys = ["planId", "ledgerDiff", "unlisted", "drift",
  "collisions", "transitions", "floorIntroduced", "floorWeakened",
  "floorExceptions", "liveJudged", "base", "storeSpace", "closureSources",
  "staticTree", "sysctlObserved"]

proc checkNoRenderedText(j: JsonNode) =
  ## Exactly the documented keys, and none of them a whole rendered section.
  check j.kind == JObject
  for k in DocumentedKeys:
    check j.hasKey(k)
  for k, _ in j.pairs:
    check k in DocumentedKeys
  check not j.hasKey("report")

suite "the add-on plan's JSON carries structured sections":
  test "a real plan over a fixture: the collision report is records":
    let state = createTempDir("repro-addon-planjson-", "")
    let etc = createTempDir("repro-addon-planjson-etc-", "")
    createDir(state / "addon")
    defer:
      removeDir(state)
      removeDir(etc)
    writeFile(state / "addon" / "own.profile", "")
    writeFile(state / "addon" / "user.profile", "")
    writeLedger(state / "addon-ledger", Ledger(generation: "g1"))
    createDir(etc / "var/lib/dpkg/info")
    writeFile(etc / "var/lib/dpkg/status", "")
    let d = newDpkgDriver(etc, proc(u: string): UnitProvision {.gcsafe.} =
      UnitProvision(loadState: "not-found"))
    let r = runAddonApply(AddonApplyOptions(stateDir: state,
      userProfileText: "addOn {\n  managedEtcPrefixes = " &
        "[\"/etc/repro-planjson-fixture/\"]\n}\n\n" &
        "fs.systemFile {\n  path = \"/etc/repro-planjson-fixture/a.conf\"\n" &
        "  content = \"a\"\n}\n",
      planOnly: true, driver: d,
      baseIdentity: some(BaseIdentity(id: "debian", versionId: "13",
                                      architecture: "amd64"))))
    check r.collisions.len > 0
    let j = addonSectionsJson(r)
    checkNoRenderedText(j)
    check j["planId"].getStr == r.planId
    check j["collisions"].len == r.collisions.len
    for i, l in r.collisions:
      let o = j["collisions"][i]
      check o["verdict"].getStr == l.verdict
      check o["target"].getStr == l.target
      check o["observation"].getStr == l.observation
      check o["address"].getStr == l.address
      check o["reason"].getStr == l.reason
    check j["ledgerDiff"].len == r.ledgerDiff.len
    check j["ledgerDiff"].len > 0
    for i, line in r.ledgerDiff:
      let o = j["ledgerDiff"][i]
      check line == o["verb"].getStr & "\t" & o["target"].getStr & "\t" &
                    o["detail"].getStr
    check j["base"]["id"].getStr == "debian"
    check j["base"]["versionId"].getStr == "13"
    check j["base"]["description"].getStr == "debian 13 amd64"
    # No string in the document is a whole rendered section.
    for v in j.pairs:
      if v.val.kind == JString:
        check "\n" notin v.val.getStr

  test "every section the text form prints has its own key":
    var r = AddonApplyResult(planId: "p1",
      ledgerDiff: @["create\t/etc/x.conf\tsystemFile:/etc/x.conf"],
      unlisted: @["systemFile:/etc/gone.conf"],
      drift: @["/etc/y.conf: changed out of band"],
      collisions: @[CollisionLine(address: "systemFile:/etc/x.conf",
        target: "/etc/x.conf", observation: "absent", verdict: "create",
        reason: "nothing there")],
      transitions: @[Transition(unit: "a.service", verb: tvRestart,
        reason: "unit file changed"),
        Transition(unit: "b.service", verb: tvStopStart,
          reason: "exclusive", exclusive: true)],
      floorIntroduced: @["a.service"], floorWeakened: @["e.service (x)"],
      floorExceptions: @["f.service: UMask: needed"],
      liveJudged: @["a.service"], storeSpace: "12 MiB of 3 GiB free",
      closureSources: @["/repro/store/prefixes/a/1 (download)"],
      staticTree: "/repro/static/g2",
      sysctlObserved: @[(key: "net.ipv4.ip_forward", value: "0")],
      previousGenerationId: "g1",
      baseIdentity: BaseIdentity(id: "debian", versionId: "13",
        versionCodename: "trixie", architecture: "amd64",
        systemd: "systemd 257 (257.9-1)",
        coupled: @[CoupledUnit(unit: "ssh.service", reason: "ships sshd")]),
      previousBase: BaseIdentity(id: "debian", versionId: "12"),
      baseChanges: @["distribution: debian 12 -> debian 13"])
    let j = addonSectionsJson(r)
    checkNoRenderedText(j)
    check j["ledgerDiff"] == %*[{"verb": "create", "target": "/etc/x.conf",
                                  "detail": "systemFile:/etc/x.conf"}]
    check j["unlisted"] == %["systemFile:/etc/gone.conf"]
    check j["drift"] == %["/etc/y.conf: changed out of band"]
    check j["transitions"] == %*[
      {"verb": "restart", "unit": "a.service", "reason": "unit file changed",
       "exclusive": false},
      {"verb": "stop-start", "unit": "b.service", "reason": "exclusive",
       "exclusive": true}]
    # The transition records read back the same as the text form's lines.
    check parseTransitions(renderTransitions(r.transitions)) == r.transitions
    check j["floorIntroduced"] == %["a.service"]
    check j["floorWeakened"] == %["e.service (x)"]
    check j["floorExceptions"] == %["f.service: UMask: needed"]
    check j["liveJudged"] == %["a.service"]
    check j["storeSpace"].getStr == "12 MiB of 3 GiB free"
    check j["closureSources"] == %["/repro/store/prefixes/a/1 (download)"]
    check j["staticTree"].getStr == "/repro/static/g2"
    check j["sysctlObserved"] == %*[{"key": "net.ipv4.ip_forward",
                                     "value": "0"}]
    let b = j["base"]
    check b["description"].getStr == "debian 13 (trixie) amd64, systemd 257"
    check b["identityDigest"].getStr == baseIdentityDigest(r.baseIdentity)
    check b["previousGenerationId"].getStr == "g1"
    check b["previousDescription"].getStr == "debian 12"
    check b["changes"] == %["distribution: debian 12 -> debian 13"]
    check b["baseCoupled"] == %*[{"unit": "ssh.service",
                                  "reason": "ships sshd"}]

  test "a plan without a base observation has base null":
    let j = addonSectionsJson(AddonApplyResult(planId: "p"))
    checkNoRenderedText(j)
    check j["base"].kind == JNull
    check j["collisions"].len == 0
    check j["transitions"].len == 0

suite "repro infra|system plan --json builds addOn from the structured sections":
  test "the add-on branch of runInfraPlan uses addonSectionsJson and no text":
    # runInfraPlan cannot be driven here (header); its add-on branch is held
    # to the one proc the cases above check. Restoring the inline
    # ``{"planId", "ledgerDiff", "drift", "report"}`` literal fails this.
    let infra = currentSourcePath().parentDir.parentDir.parentDir /
      "repro_cli_support/src/repro_cli_support/infra.nim"
    let src = readFile(infra)
    let a = src.find("if addon_apply.isAddonHost(stateDir):")
    check a >= 0
    let b = src.find("except CatchableError", a)
    check b > a
    let branch = src[a ..< b]
    check "addOnJson = addon_cli.addonSectionsJson(r)" in branch
    check "renderAddonSections" notin branch.split("else:")[0]
    check "\"report\"" notin branch
