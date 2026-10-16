## GM7: the `applies:` declaration of a `hosts:` entry through the CLI
## (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped
## apply).
##
## `e2e_hosts_applies_declaration_cli`, against the real `build/bin/repro`:
##
## 1. A block-form entry compiles; `repro home apply --plan` for that host
##    prints the applied set and lists the other concerns' operations as not
##    applied, and exits 0 although a package of the `packages` concern has
##    no realization. Negative control: the same profile planned for an
##    undeclared host exits 1 on that package (`missing` is drift there, as
##    before).
## 2. `repro home export` carries the declaration (`intent.hostApplies`) and
##    the classification (`concerns`); `--target` reports `applies` for the
##    declared host only.
## 3. `repro home facts` reports the declaration (`concerns`), and
##    `repro home compare` names the side that applies each category.
## 4. The profile refuses, at compile time and naming the host, an unknown
##    concern, a concern named twice, an unknown key and a repeated key
##    (Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped).
## 5. The text parser and structural editor read the block form:
##    `repro home enable <activity> --host <declared> --no-apply` rewrites the
##    `activities:` line and keeps `applies:`; the edited profile compiles to
##    the same declaration.
## 6. (macOS) On a host that gives Reprobuild the applications and Nix the
##    packages, `--plan` refuses a package whose selection here (PATH, ahead
##    of the disk image in `adapterPreference`) would put it in another
##    concern than the export's classification; it does not refuse without
##    the binary on PATH, nor for a host that keeps both concerns together.
##    The export classifies every system and refuses to classify, naming
##    the package, when no reprobuild-packages catalog is reachable and a
##    package is defined nowhere.
##
## Vacuity: the plan lists at least one not-applied operation per undeclared
## concern the profile uses, and the export's declaration is non-empty.
##
## No mocks: real `repro`, real Nim, real io-mon shim, real filesystem; the
## `nim` spy is the harness's pass-through counter.

import std/[json, os, strutils, unittest]

import ../m83/profile_compile_edge_harness

const
  Declared = "gm7-declared"
  Undeclared = "gm7-undeclared"

proc profileText(hostsBlock: string; withResources = true): string =
  result = """
import repro_profile

profile "gm7Cli":
  activity default:
    gm7nosuchpackage

  activity desktop:
    gm7nosuchpackage

  hosts:
""" & hostsBlock
  if withResources:
    result.add """

  resources:
    fsUserFile(hostFile = "~/.gm7-cli-marker", content = "x\n")
    fsManagedBlock(hostFile = "~/.gm7clirc", blockId = "gm7",
      content = "export GM7=1")
"""

const PathAppCatalog = """
import repro_project_dsl

package gm7pathapp:
  provisioning:
    tarball url = "https://example.invalid/gm7/PathApp-1.0.dmg",
      sha256 = "6666666666666666666666666666666666666666666666666666666666666666",
      archiveType = "dmg",
      installMethod = "app-bundle",
      appBundle = "PathApp.app",
      bundleId = "dev.reprobuild.gm7.pathapp",
      teamId = "RPBTEST666",
      version = "1.0",
      executablePath = "PathApp.app/Contents/MacOS/PathApp",
      packageId = "gm7pathapp@1.0",
      cpu = "any",
      os = "macos",
      lockIdentity = "tarball:gm7pathapp@1.0:macos-any:sha256:6666"
"""

const SplitProfile = """
import repro_profile

profile "gm7Split":
  adapterPreference:
    darwin: [path, tarball]

  activity default:
    package(gm7pathapp, binaries = @["gm7pathapp-bin"])

  hosts:
    "gm7-declared":
      applies: [applications]
    "gm7-undeclared":
      applies: [applications, packages]
"""

const DeclaredHosts = """
    "gm7-declared":
      activities: [desktop]
      applies: [files]
    "gm7-undeclared": [desktop]
"""

suite "GM7: the hosts applies declaration through the CLI":

  test "e2e_hosts_applies_declaration_cli":
    let sb = newProfileSandbox("gm7-applies", profileText(DeclaredHosts))
    defer: sb.dispose()
    sb.writeProfileFile("stow/gm7dots/.gm7-cli-dotfile", "dotfile\n")

    # 1. --plan for the declared host.
    let plan = sb.runRepro(["home", "apply", "--plan"], host = Declared)
    checkpoint "plan (declared):\n" & plan.stdout & plan.stderr
    check plan.exitCode == 0
    check "concerns applied: files (hosts." & Declared & ".applies)" in
      plan.stdout
    check "[not applied on " & Declared & ": concern packages" in plan.stdout
    check "[not applied on " & Declared & ": concern environment" in
      plan.stdout
    check "missing  gm7nosuchpackage" in plan.stdout
    # The applied concern's operations are in the ordinary sections.
    check "[stow]" in plan.stdout
    check ".gm7-cli-dotfile" in plan.stdout
    # Negative control: the undeclared host plans every concern, and the
    # package with no realization is drift there.
    let planU = sb.runRepro(["home", "apply", "--plan"], host = Undeclared)
    checkpoint "plan (undeclared):\n" & planU.stdout & planU.stderr
    check planU.exitCode == 1
    check "not applied on" notin planU.stdout
    check "concerns applied" notin planU.stdout

    # 2. The export carries the declaration and the classification.
    let exported = sb.runRepro(["home", "export", "--format", "json"],
      host = Declared)
    checkpoint exported.stderr
    require exported.exitCode == 0
    let doc = parseJson(exported.stdout)
    check doc["intent"]["hostApplies"] == %*{Declared: ["files"]}
    check doc["concerns"]["names"] == %*["packages", "applications",
      "files", "environment", "services", "settings"]
    check doc["concerns"]["resourceKinds"]["fs.userFile"] == %"files"
    check doc["concerns"]["resourceKinds"]["launchd.userAgent"] ==
      %"services"
    check doc["concerns"]["configOverrides"] == %"files"
    let target = sb.runRepro(["home", "export", "--format", "json",
      "--target", "x86_64-linux"], host = Declared)
    require target.exitCode == 0
    check parseJson(target.stdout)["evaluation"]["applies"] == %*["files"]
    let targetU = sb.runRepro(["home", "export", "--format", "json",
      "--target", "x86_64-linux"], host = Undeclared)
    require targetU.exitCode == 0
    check not parseJson(targetU.stdout)["evaluation"].hasKey("applies")
    # The per-package classification, for every target system: the package
    # nothing defines resolves to nothing (`packages`, `unresolved`), and the
    # evaluation carries its concern.
    for system in ["x86_64-linux", "aarch64-linux", "x86_64-darwin",
                   "aarch64-darwin", "x86_64-windows", "aarch64-windows"]:
      let row = doc["concerns"]["packages"][system]
      check row["applications"].len == 0
      check row["unresolved"] == %*["gm7nosuchpackage"]
    let evaluated = parseJson(target.stdout)["evaluation"]["packages"]
    require evaluated.len == 1
    check evaluated[0]["concern"] == %"packages"
    check evaluated[0]["resolved"] == %false
    check not parseJson(targetU.stdout)["evaluation"]["packages"][0].hasKey(
      "concern")
    # With no reprobuild-packages catalog reachable, a package defined
    # nowhere might be a catalog application: the export refuses to classify
    # rather than publish a guess, naming it and the remedy.
    let noCatalog = sb.runRepro(["home", "export", "--format", "json"],
      host = Declared,
      extraEnv = [("REPROBUILD_PACKAGES_ROOT", sb.root / "no-catalog-here")])
    checkpoint noCatalog.stderr
    check noCatalog.exitCode != 0
    check "gm7nosuchpackage" in noCatalog.stderr
    check "REPROBUILD_PACKAGES_ROOT" in noCatalog.stderr
    # --check: a snapshot is current, and stale once the declaration moves.
    let snapshot = sb.root / "export.json"
    writeFile(snapshot, exported.stdout)
    check sb.runRepro(["home", "export", "--check", snapshot],
      host = Declared).exitCode == 0

    # 3. Host facts report the declaration; compare names the owners.
    let facts = sb.runRepro(["home", "facts"], host = Declared)
    checkpoint facts.stderr
    require facts.exitCode == 0
    let factsDoc = parseJson(facts.stdout)
    check factsDoc["concerns"] == %*{"declared": true, "applied": ["files"]}
    # The facts still describe every concern (the stow file and the block).
    var fileIds: seq[string]
    for e in factsDoc["categories"]["files"]: fileIds.add e["id"].getStr
    check "~/.gm7-cli-dotfile" in fileIds
    check factsDoc["categories"]["environment"].len > 0
    var nixDoc = factsDoc.copy()
    nixDoc["side"] = %"nix"
    nixDoc.delete("concerns")
    writeFile(sb.root / "nix.json", $nixDoc)
    writeFile(sb.root / "repro.json", facts.stdout)
    let compared = sb.runRepro(["home", "compare", "--facts",
      sb.root / "nix.json", "--facts", sb.root / "repro.json"],
      host = Declared)
    checkpoint compared.stdout & compared.stderr
    check compared.exitCode == 0
    check "-- applied by reprobuild on " & Declared in compared.stdout
    check "-- applied by nix on " & Declared in compared.stdout
    check "split" notin compared.stdout  # packages: neither side's half
    let factsU = sb.runRepro(["home", "facts"], host = Undeclared)
    require factsU.exitCode == 0
    check parseJson(factsU.stdout)["concerns"]["declared"].getBool == false

    # 4. Refusals at compile time, naming the host.
    for (bad, expected) in [
        ("""
    "gm7-declared":
      activities: [desktop]
      applies: [apps]
""", "applies: unknown concern `apps`"),
        ("""
    "gm7-declared":
      applies: [files, files]
""", "concern `files` is named twice"),
        ("""
    "gm7-declared":
      activities: [desktop]
      owner: [nix]
""", "unknown key `owner:`"),
        ("""
    "gm7-declared":
      applies: [files]
      applies: [packages]
""", "`applies:` is given twice")]:
      sb.writeProfileFile("home.nim", profileText(bad))
      let r = sb.runRepro(["home", "apply", "--plan"], host = Declared)
      checkpoint "refusal case:\n" & bad & "\n" & r.stdout & r.stderr
      check r.exitCode != 0
      check expected in (r.stdout & r.stderr)
      check Declared in (r.stdout & r.stderr)

    # 5. The structural editor on the block form (the text parser reads only
    # the resource-free profile: its `resources:` grammar is the text form).
    sb.writeProfileFile("home.nim", profileText("""
    "gm7-declared":
      activities: [desktop]
      applies: [files]
""", withResources = false) & """

  activity extra:
    gm7nosuchpackage
""")
    let enabled = sb.runRepro(["home", "enable", "extra", "--host",
      Declared, "--no-apply"], host = Declared)
    checkpoint enabled.stdout & enabled.stderr
    check enabled.exitCode == 0
    let edited = readFile(sb.profilePath)
    checkpoint edited
    check "      activities: [desktop, extra]\n" in edited
    check "      applies: [files]\n" in edited
    let reexported = sb.runRepro(["home", "export", "--format", "json"],
      host = Declared)
    require reexported.exitCode == 0
    let redoc = parseJson(reexported.stdout)
    check redoc["intent"]["hostApplies"] == %*{Declared: ["files"]}
    check redoc["selection"]["activities"] == %*["default", "desktop",
      "extra"]

    when defined(macosx):
      # 6. A host that gives Reprobuild the applications and Nix the
      # packages, where this host's selection can use PATH: with the
      # application's binary on PATH and `path` ahead of `tarball` in the
      # policy, this host would select `path` (a plain package) while the
      # export -- which cannot see this PATH -- classifies it an
      # application. Both sides would skip it; the plan refuses instead.
      let appDir = sb.root / "reprobuild-packages" / "packages" /
        "interfaces" / "gm7pathapp"
      createDir(appDir)
      writeFile(appDir / "repro.nim", PathAppCatalog)
      let binDir = sb.root / "path-bin"
      createDir(binDir)
      writeFile(binDir / "gm7pathapp-bin", "#!/bin/sh\nexit 0\n")
      setFilePermissions(binDir / "gm7pathapp-bin",
        {fpUserRead, fpUserWrite, fpUserExec})
      sb.writeProfileFile("home.nim", SplitProfile)
      let withPath = @[("PATH", binDir & ":" & getEnv("PATH"))]
      let refused = sb.runRepro(["home", "apply", "--plan"], host = Declared,
        extraEnv = withPath)
      checkpoint "split, binary on PATH:\n" & refused.stdout & refused.stderr
      check refused.exitCode != 0
      check "gm7pathapp is `packages` by this host's selection" in
        refused.stderr
      check "adapterPreference" in refused.stderr
      # Control: without the binary on PATH both select the disk image.
      let agreed = sb.runRepro(["home", "apply", "--plan"], host = Declared)
      checkpoint "split, no binary:\n" & agreed.stdout & agreed.stderr
      check agreed.exitCode == 0
      check "[app-bundle]" in agreed.stdout
      # Control: a host that keeps both concerns on one side is not refused.
      let together = sb.runRepro(["home", "apply", "--plan"],
        host = Undeclared, extraEnv = withPath)
      checkpoint "together, binary on PATH:\n" & together.stdout &
        together.stderr
      check together.exitCode == 0
