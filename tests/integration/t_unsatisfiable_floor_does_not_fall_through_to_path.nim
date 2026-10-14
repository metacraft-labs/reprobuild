## PMC-4 — an unsatisfiable microarchitecture floor must not fall through to
## `path`.
##
## ## Why this test exists
##
## PMC-1 closed this hazard on the AVAILABILITY axis. `Package-Model.md`:
## "`path` stops being reachable for a package known to be unavailable,
## closing the silent-fallthrough-to-PATH hole." The gate sits in front of the
## adapter loop, because availability is known before any adapter runs.
##
## PMC-2/PMC-3 then added a second way for a package to be unusable here: the
## catalog HAS a slice for this cpu/os, and the host cannot execute it. That
## refusal happens while the ``tarball`` kind selects, after PMC-1's gate —
## and the policy walks on to `path`, which probes PATH for a same-named
## executable.
##
## The result was PMC-1's hazard wearing new clothes, and worse than the
## original: the user asks for a package with an x86-64-v3 floor, the resolver
## correctly refuses it, and then hands back whatever `foo.exe` happened to be
## first on PATH — reporting success. Nothing anywhere says the artifact is
## not the one that was refused.
##
## GM4b: the gate lives in ``realization_selection.selectRealization`` —
## the one selection a recipe's ``uses:`` and a home profile share — and is
## driven END TO END here: a v3-only ``tarball`` record, a v2 target, and a
## same-named executable really planted on PATH.
##
## ## What is asserted, and what is deliberately NOT
##
## Only `path` is poisoned. `cakNix` and `cakScoop` resolve genuinely
## different artifacts that may well satisfy this host; refusing those would
## turn a safety fix into an outage. That distinction is pinned below, because
## "refuse everything after a shortfall" is the plausible over-correction.

## Falsifiable: drop the ``capabilityRefusal`` guard in front of the ``path``
## step in ``selectRealization`` and the first behavioural case resolves the
## planted stub; make the guard refuse every later kind and the ``nix`` case
## fails.
##
## No mocks: the real PATH inventory probe over a temp directory holding the
## planted executable; the records are synthetic ``InterfaceToolUse`` data,
## which is what selection consumes.

import std/[options, os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles/realization_selection
import repro_home_apply/package_catalog

const
  V3Url = "https://example.invalid/demo-2.0.0-linux-x86-64-v3.tar.gz"
  V3Sha = "3333333333333333333333333333333333333333333333333333333333333333"

proc demoUse(withNix: bool): InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: "pmc4demo",
    packageSelector: "pmc4demo", executableName: "pmc4demo")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "pmc4demo", url: V3Url, sha256: V3Sha,
    archiveType: "tar.gz", executablePath: "bin/pmc4demo",
    cpu: "x86_64", os: "linux",
    detail: TarballArchiveDetail(version: "2.0.0", cpuLevel: "x86-64-v3"))]
  if withNix:
    result.nixProvisioning = @[InterfaceNixProvisioning(
      packageName: "pmc4demo", selector: "nixpkgs#hello",
      executablePath: "bin/hello")]

proc request(target: RealizationTarget; policy: SelectionPolicy):
    SelectionRequest =
  SelectionRequest(packageName: "pmc4demo", target: target, policy: policy,
    probeNames: @["pmc4demo"], definitionKnown: true,
    inventory: HostInventory(probePath: pathInventoryProbe()))

suite "PMC-4 — a capability refusal does not fall through to PATH":
  let scratch = createTempDir("repro-pmc4-path-", "")
  let binDir = scratch / "bin"
  createDir(binDir)
  let planted = binDir / (when defined(windows): "pmc4demo.cmd"
                          else: "pmc4demo")
  writeFile(planted, when defined(windows): "@echo stub\r\n"
                     else: "#!/bin/sh\necho stub\n")
  when not defined(windows):
    setFilePermissions(planted, {fpUserRead, fpUserWrite, fpUserExec})
  let originalPath = getEnv("PATH")
  putEnv("PATH", binDir & PathSep & originalPath)
  let v2Host = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v2,
    isHost = true)
  let v3Host = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v3,
    isHost = true)

  test "the planted executable is really on PATH (precondition)":
    check findExe("pmc4demo").len > 0

  test "control: without an archive for the target, path DOES select it":
    # The same planted binary, a use that declares nothing: PATH is reached.
    var bare = demoUse(false)
    bare.tarballProvisioning = @[]
    let s = selectRealization(bare, request(v2Host, @[rkTarball, rkPath]))
    check s.kind == rkPath
    check s.pathExecutable.extractFilename.startsWith("pmc4demo")

  test "a v3-only archive on a v2 target does NOT fall through to PATH":
    var raised = false
    try:
      discard selectRealization(demoUse(false),
        request(v2Host, @[rkTarball, rkPath]))
    except EMissingRealization as err:
      raised = true
      check err.steps.len == 2
      check err.steps[0].kind == rkTarball
      # A TYPED signal, not a substring of the reason.
      check err.steps[0].capabilityShortfall
      check "needs x86-64-v3" in err.steps[0].reason
      check err.steps[1].kind == rkPath
      check err.steps[1].capabilityShortfall
      # The refusal names why PATH was not consulted.
      for token in ["refused", "cannot run it", "PATH", "undeclared"]:
        check token in err.steps[1].reason
    check raised

  test "a capability refusal and a plain miss are different things":
    # A record for another OS is a plain miss: the next kind may run.
    var miss = demoUse(false)
    miss.tarballProvisioning[0].os = "windows"
    let s = selectRealization(miss, request(v2Host, @[rkTarball, rkPath]))
    check s.kind == rkPath
    check not s.trace[0].capabilityShortfall

  test "only path is poisoned, not the whole policy":
    # nix resolves a DIFFERENT artifact that may satisfy this host.
    let s = selectRealization(demoUse(true),
      request(v2Host, @[rkTarball, rkNix, rkPath]))
    check s.kind == rkNix
    check s.trace[0].capabilityShortfall
    # And the default policy still ends at path, or the gate is guarding a
    # step that no longer exists.
    check DefaultSelectionPolicy[^1] == rkPath

  test "positive control: a target that satisfies the floor selects it":
    let s = selectRealization(demoUse(false),
      request(v3Host, @[rkTarball, rkPath]))
    check s.kind == rkTarball
    check s.tarball.url == V3Url

  putEnv("PATH", originalPath)
  removeDir(scratch)
