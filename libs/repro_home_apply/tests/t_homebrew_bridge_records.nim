## GM5b: Homebrew bridge records -- `brewCask` / `brewFormula` in a
## `provisioningFor` contribution.
##
## A Homebrew record says which cask or formula installs a canonical package
## OUTSIDE Reprobuild, for consumers that still install through Homebrew (the
## reprobuild flake's `reprobuild.lib.brewRealizationOf`, the equivalence
## report). reprobuild-pm spec Provisioning-Contributions.md §"Homebrew
## bridge records" makes two promises, and this file holds both:
##
## * the record is carried wherever contribution records go -- the interface
##   artifact's `provisioningContributions`, the v27 codec, the published
##   contribution-records JSON and the thin-interface stub a consumer
##   compiles -- with its kind, token, tap and source location;
## * Reprobuild never realizes it: it never becomes a realization candidate
##   of a tool use, so a recipe's `uses:` and a profile's package reference
##   resolve as if it were absent (a package only Homebrew claims is a
##   missing realization), and a selection policy naming Homebrew is refused
##   with that reason.
##
## Falsifying mutations: adding `projected.homebrewProvisioning` to the tool
## use in `toProjectInterface` (needs a matching field) or dropping the
## record from `toInterfaceProvisioningContribution` fails "the record is
## in the contribution and in no tool use"; dropping it from the v27 codec
## fails "the v27 codec keeps the record"; dropping it from
## `emitProvisioningContributionRegistrations` fails the stub case.
##
## No mocks: the real `provisioningFor` / `package` macros register the
## fixtures in this process, the real codec, renderer, resolver and a real
## `nim c` / `nim check` of generated sources.

import std/[json, options, os, osproc, strutils, tables, tempfiles, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_interface_artifacts/contribution_records
import repro_home_apply
import repro_home_apply/package_catalog

package gm5bapp:
  provisioning:
    nixPackage "nixpkgs#hello", executablePath = "bin/hello"

package gm5bonly:
  discard

provisioningFor "gm5bapp":
  developInterface
  contributor "github:example/gm5b-brew-catalog"
  brewCask "gm5b-app"

provisioningFor "gm5bonly":
  developInterface
  contributor "github:example/gm5b-brew-catalog"
  brewFormula "gm5b-only@2", tap = "example/tap"

proc contributionFor(pi: ProjectInterface; target: string):
    InterfaceProvisioningContribution =
  for c in pi.provisioningContributions:
    if c.targetPackage == target:
      return c
  raise newException(KeyError, "no contribution for " & target)

proc consumer(): ProjectInterface =
  ## A recipe that `uses:` both packages, projected exactly as interface
  ## extraction projects one (`toProjectInterface` with the registry).
  var pkg = PackageDef(packageName: "gm5bconsumer",
    sourceFile: currentSourcePath(), sourceLine: 1)
  for name in ["gm5bapp", "gm5bonly"]:
    pkg.toolUses.add(PackageUseDef(rawConstraint: name, packageSelector: name,
      executableName: name, sourceFile: currentSourcePath(), sourceLine: 1))
  toProjectInterface(pkg, registeredPackages(),
    registeredProvisioningContributions())

proc macos(): RealizationTarget =
  profileRealizationTarget("macos", "arm64", isHost = false)

suite "GM5b: Homebrew bridge records":

  test "the record is in the contribution and in no tool use":
    let pi = consumer()
    let app = contributionFor(pi, "gm5bapp")
    check app.homebrewProvisioning.len == 1
    check app.homebrewProvisioning[0].kind == "cask"
    check app.homebrewProvisioning[0].token == "gm5b-app"
    check app.homebrewProvisioning[0].tap == ""
    check app.homebrewProvisioning[0].contributor ==
      "github:example/gm5b-brew-catalog"
    check app.homebrewProvisioning[0].packageName == "gm5bapp"
    check app.homebrewProvisioning[0].location.line > 0
    let only = contributionFor(pi, "gm5bonly")
    check only.homebrewProvisioning.len == 1
    check only.homebrewProvisioning[0].kind == "formula"
    check only.homebrewProvisioning[0].token == "gm5b-only@2"
    check only.homebrewProvisioning[0].tap == "example/tap"
    # The tool uses carry the package's own realizations and nothing a
    # Homebrew record could have become.
    var seen = 0
    for u in pi.toolUses:
      if u.packageSelector == "gm5bapp":
        check u.nixProvisioning.len == 1
        check u.tarballProvisioning.len == 0
        check u.scoopProvisioning.len == 0
        inc seen
      elif u.packageSelector == "gm5bonly":
        check u.nixProvisioning.len == 0
        check u.tarballProvisioning.len == 0
        check u.scoopProvisioning.len == 0
        inc seen
    check seen == 2

  test "the v27 codec keeps the record; a v26 payload decodes without it":
    let pi = consumer()
    let roundTrip = decodeInterfacePayload(encodeInterfacePayload(pi))
    let only = contributionFor(roundTrip, "gm5bonly")
    check only.homebrewProvisioning.len == 1
    check only.homebrewProvisioning[0].token == "gm5b-only@2"
    check only.homebrewProvisioning[0].tap == "example/tap"
    check only.homebrewProvisioning[0].kind == "formula"
    let old = decodeInterfacePayload(encodeInterfacePayload(pi, 26'u16),
      26'u16)
    check contributionFor(old, "gm5bonly").homebrewProvisioning.len == 0
    check contributionFor(old, "gm5bapp").targetPackage == "gm5bapp"

  test "the published contribution records carry the record":
    let pi = consumer()
    let root = currentSourcePath().parentDir
    let doc = contributionRecordsJson(pi.provisioningContributions, root)
    var tokens: seq[string] = @[]
    for c in doc["contributions"]:
      for r in c["homebrewProvisioning"]:
        tokens.add(r["kind"].getStr & ":" & r["token"].getStr)
        check r["location"]["file"].getStr == "t_homebrew_bridge_records.nim"
    check tokens == @["cask:gm5b-app", "formula:gm5b-only@2"]

  test "the thin-interface stub registers the record":
    let pi = consumer()
    let artifact = ProjectInterfaceArtifact(projectInterface: pi)
    let tempRoot = createTempDir("repro-gm5b-stub", "", getCurrentDir())
    defer: removeDir(tempRoot)
    writeNimInterfaceStub(tempRoot / "gm5b_interface.nim", artifact)
    let probe = tempRoot / "gm5b_probe.nim"
    writeFile(probe,
      "import repro_project_dsl\n" &
      "import gm5b_interface\n" &
      "var tokens: seq[string]\n" &
      "for c in registeredProvisioningContributions():\n" &
      "  for r in c.homebrewProvisioning:\n" &
      "    tokens.add(c.targetPackage & \"=\" & r.kind & \":\" & r.token & " &
      "\"@\" & r.tap)\n" &
      "doAssert tokens == @[\"gm5bapp=cask:gm5b-app@\", " &
      "\"gm5bonly=formula:gm5b-only@2@example/tap\"], $tokens\n" &
      "echo \"stub-homebrew-ok\"\n")
    let (output, exitCode) = execCmdEx(
      "nim c -r --hints:off --warnings:off --path:" &
        quoteShell(getCurrentDir() / "libs" / "repro_project_dsl" / "src") &
        " --out:" & quoteShell(tempRoot / "gm5b_probe") & " " &
        quoteShell(probe))
    if exitCode != 0:
      checkpoint output
    check exitCode == 0
    check "stub-homebrew-ok" in output

  test "a profile reference never resolves to a Homebrew record":
    # gm5bapp resolves to its own Nix realization; the Homebrew contribution
    # changes nothing.
    let app = resolveProfilePackage("gm5bapp", macos(), @[rkTarball, rkNix])
    check app.selection.kind == rkNix
    check app.selection.nix.selector == "nixpkgs#hello"
    # gm5bonly is claimed ONLY by Homebrew: a definition is in scope, so it
    # is a missing realization, not an unknown package, and nothing is
    # selected.
    var raised = false
    try:
      discard resolveProfilePackage("gm5bonly", macos(),
        @[rkTarball, rkNix, rkScoop])
    except EMissingRealization as e:
      raised = true
      check e.definitionKnown
      check "no realization of package 'gm5bonly'" in e.msg
    check raised
    # (review) No selection policy reaches a Homebrew record: under every
    # realization kind on its own, and under all of them together, a package
    # whose only record is Homebrew's stays a missing realization, and one
    # whose own realization the policy excludes is not handed its cask
    # instead. The token never appears in what the resolver reports.
    var policies: seq[SelectionPolicy] = @[]
    for kind in RealizationKind:
      policies.add(@[kind])
    policies.add(@[rkTarball, rkNix, rkScoop, rkPath])
    for policy in policies:
      for (name, token) in [("gm5bonly", "gm5b-only"),
                            ("gm5bapp", "gm5b-app")]:
        if name == "gm5bapp" and rkNix in policy:
          continue
        checkpoint name & " under " & $policy
        var missing = false
        try:
          let r = resolveProfilePackage(name, macos(), policy)
          checkpoint "selected " & $r.selection.kind
        except EMissingRealization as e:
          missing = true
          check token notin e.msg
        check missing

  test "a selection policy naming Homebrew is refused with the reason":
    for token in ["homebrew", "brew", "Homebrew"]:
      var pref = initOrderedTable[string, seq[string]]()
      pref["darwin"] = @["tarball", token]
      var raised = false
      try:
        discard selectionPolicyFor(pref, poMacos)
      except ValueError as e:
        raised = true
        check "bridge records" in e.msg
        check "does not realize packages through Homebrew" in e.msg
      check raised

  test "authoring errors: package-level Homebrew, a bad token, a bad tap":
    let tempRoot = createTempDir("repro-gm5b-authoring", "", getCurrentDir())
    defer: removeDir(tempRoot)
    proc checkSource(body: string): tuple[output: string; exitCode: int] =
      let source = tempRoot / "bad_brew.nim"
      writeFile(source, "import repro_project_dsl\n" &
        "package gm5bTarget:\n  discard\n" & body)
      execCmdEx("nim check --hints:off --warnings:off --path:" &
        quoteShell(getCurrentDir() / "libs" / "repro_project_dsl" / "src") &
        " " & quoteShell(source))
    let ok = checkSource("provisioningFor \"gm5bTarget\":\n" &
      "  developInterface\n  contributor \"github:example/c\"\n" &
      "  brewCask \"gm5b-target\"\n")
    checkpoint ok.output
    check ok.exitCode == 0
    let inPackage = checkSource("package gm5bOther:\n  provisioning:\n" &
      "    brewCask \"gm5b-other\"\n")
    check inPackage.exitCode != 0
    check "contribution-only Homebrew bridge record" in inPackage.output
    let upper = checkSource("provisioningFor \"gm5bTarget\":\n" &
      "  developInterface\n  contributor \"github:example/c\"\n" &
      "  brewCask \"Visual-Studio-Code\"\n")
    check upper.exitCode != 0
    check "is not a Homebrew token" in upper.output
    let tap = checkSource("provisioningFor \"gm5bTarget\":\n" &
      "  developInterface\n  contributor \"github:example/c\"\n" &
      "  brewFormula \"x\", tap = \"no-slash\"\n")
    check tap.exitCode != 0
    check "is not <owner>/<repo>" in tap.output
    let notLiteral = checkSource("const T = \"x\"\n" &
      "provisioningFor \"gm5bTarget\":\n" &
      "  developInterface\n  contributor \"github:example/c\"\n" &
      "  brewCask T\n")
    check notLiteral.exitCode != 0
    check "token as a string literal" in notLiteral.output
