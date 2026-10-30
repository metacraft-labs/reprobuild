## GM10: the `system:` key of a `hosts:` entry through the home CLI
## (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §Hosts,
## feature 2; §Export schema, version 4).
##
## `e2e_hosts_system_attribute_export_and_refusals`, against the real
## `build/bin/repro`:
##
## 1. The export (schema 5, since ReproOS add-on mode) carries the attribute:
##    `intent.hostSystems` names exactly the hosts that say `system:
##    managedElsewhere[(...)]`, with the pointer or `null`; `--target` reports
##    `evaluation.system` for every host -- `elsewhere` with the pointer,
##    `elsewhere` with `null`, and `here` (mode `full`) for the host without
##    the key (negative control). A profile with no such host exports no
##    `hostSystems` key at all. (Add-on hosts: `tests/e2e/addon/`.)
## 2. `repro home export --check` sees an attribute edit: a snapshot is
##    current, and stale once a pointer changes.
## 3. The attribute does not change what the home side plans: `repro home
##    apply --plan` for the host managed elsewhere plans its home packages
##    like any other host (home scope is always this profile's).
## 4. Refusals at compile time, naming the host (Core-Invariants.md
##    §Unrecognised Input Is Rejected, Not Skipped): an unknown value, a
##    pointer that is not a string literal, an empty pointer, a pointer with
##    a line break, and `system:` given twice.
## 5. The text parser and structural editor read the key: `repro home list`
##    reads the profile, and `repro home enable <activity> --host <host>
##    --no-apply` rewrites the `activities:` line and keeps the `system:`
##    line; the edited profile exports the same attribute.
##
## Vacuity: the export's map is non-empty and the evaluations differ between
## the hosts, so "every host here" cannot pass.
##
## No mocks: real `repro`, real Nim, real io-mon shim, real filesystem
## (harness header). Nothing is applied.

import std/[json, os, strutils, unittest]

import ../m83/profile_compile_edge_harness

const Registry = """
    "gm10-here": [default]
    "gm10-elsewhere":
      activities: [default, extra]
      system: managedElsewhere("example-org/gm10-infra")
    "gm10-nopointer":
      system: managedElsewhere
"""

proc profileText(hostsBlock: string): string =
  """
import repro_profile

profile "gm10Cli":
  activity default:
    gm10nosuchpackage

  activity extra:
    gm10othermissing

  activity more:
    gm10thirdmissing

  hosts:
""" & hostsBlock

suite "GM10: the hosts system attribute through the home CLI":

  test "e2e_hosts_system_attribute_export_and_refusals":
    let sb = newProfileSandbox("gm10-cli", profileText(Registry))
    defer: sb.dispose()

    # 1. The export carries the attribute.
    let exported = sb.runRepro(["home", "export", "--format", "json"],
      host = "gm10-here")
    checkpoint exported.stderr
    require exported.exitCode == 0
    let doc = parseJson(exported.stdout)
    check doc["schemaVersion"].getInt == 5
    check doc["intent"]["hostSystems"] == %*{
      "gm10-elsewhere": {"mode": "managedElsewhere",
                         "managedBy": "example-org/gm10-infra",
                         "activities": []},
      "gm10-nopointer": {"mode": "managedElsewhere", "managedBy": nil,
                         "activities": []}}
    for (host, want) in [
        ("gm10-elsewhere", %*{"managed": "elsewhere",
                              "managedBy": "example-org/gm10-infra",
                              "mode": "managedElsewhere", "activities": []}),
        ("gm10-nopointer", %*{"managed": "elsewhere", "managedBy": nil,
                              "mode": "managedElsewhere", "activities": []}),
        ("gm10-here", %*{"managed": "here", "managedBy": nil, "mode": "full",
                         "activities": ["default"]})]:
      let target = sb.runRepro(["home", "export", "--format", "json",
        "--target", "x86_64-linux"], host = host)
      checkpoint host & ": " & target.stderr
      require target.exitCode == 0
      check parseJson(target.stdout)["evaluation"]["system"] == want
    block plainProfile:
      let plain = newProfileSandbox("gm10-cli-plain",
        profileText("    \"gm10-here\": [default]\n"))
      defer: plain.dispose()
      let r = plain.runRepro(["home", "export", "--format", "json"],
        host = "gm10-here")
      require r.exitCode == 0
      check not parseJson(r.stdout)["intent"].hasKey("hostSystems")

    # 2. --check sees a pointer edit.
    let snapshot = sb.root / "export.json"
    writeFile(snapshot, exported.stdout)
    check sb.runRepro(["home", "export", "--check", snapshot],
      host = "gm10-here").exitCode == 0
    sb.writeProfileFile("home.nim", profileText(Registry.replace(
      "example-org/gm10-infra", "example-org/other-infra")))
    let stale = sb.runRepro(["home", "export", "--check", snapshot],
      host = "gm10-here")
    checkpoint stale.stdout & stale.stderr
    check stale.exitCode == 1
    check ("intent.hostSystems.gm10-elsewhere.managedBy: " &
      "snapshot has \"example-org/gm10-infra\", a fresh export has " &
      "\"example-org/other-infra\"") in stale.stderr
    sb.writeProfileFile("home.nim", profileText(Registry))

    # 3. The home side plans the host as any other.
    let plan = sb.runRepro(["home", "apply", "--plan"],
      host = "gm10-elsewhere")
    checkpoint plan.stdout & plan.stderr
    check "missing  gm10nosuchpackage" in plan.stdout
    check "missing  gm10othermissing" in plan.stdout

    # 4. Refusals at compile time, naming the host.
    for (bad, expected) in [
        ("""
    "gm10-elsewhere":
      system: managedSomewhere
""", "unknown `system:` value `managedSomewhere`"),
        ("""
    "gm10-elsewhere":
      system: managedElsewhere(infraRepo)
""", "pointer must be a string literal"),
        ("""
    "gm10-elsewhere":
      system: managedElsewhere("  ")
""", "the pointer is empty"),
        ("""
    "gm10-elsewhere":
      system: managedElsewhere("a\nb")
""", "the pointer spans several lines"),
        ("""
    "gm10-elsewhere":
      system: managedElsewhere
      system: managedElsewhere("x")
""", "`system:` is given twice")]:
      sb.writeProfileFile("home.nim", profileText(bad))
      let r = sb.runRepro(["home", "export", "--format", "json"],
        host = "gm10-elsewhere")
      checkpoint "refusal case:\n" & bad & "\n" & r.stdout & r.stderr
      check r.exitCode != 0
      check expected in (r.stdout & r.stderr)
      check "gm10-elsewhere" in (r.stdout & r.stderr)

    # 5. The text parser and the structural editor.
    sb.writeProfileFile("home.nim", profileText(Registry))
    let listed = sb.runRepro(["home", "list"], host = "gm10-elsewhere")
    checkpoint listed.stdout & listed.stderr
    check listed.exitCode == 0
    let enabled = sb.runRepro(["home", "enable", "more", "--host",
      "gm10-elsewhere", "--no-apply"], host = "gm10-elsewhere")
    checkpoint enabled.stdout & enabled.stderr
    check enabled.exitCode == 0
    let edited = readFile(sb.profilePath)
    checkpoint edited
    check "      activities: [default, extra, more]\n" in edited
    check "      system: managedElsewhere(\"example-org/gm10-infra\")\n" in
      edited
    let reexported = sb.runRepro(["home", "export", "--format", "json"],
      host = "gm10-elsewhere")
    require reexported.exitCode == 0
    let redoc = parseJson(reexported.stdout)
    check redoc["intent"]["hostSystems"] == doc["intent"]["hostSystems"]
    check redoc["selection"]["activities"] == %*["default", "extra", "more"]
