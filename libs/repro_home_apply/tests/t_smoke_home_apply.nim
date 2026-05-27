## Smoke test for the M63 apply pipeline library. Pins the public
## API surface compiles, the planner produces deterministic plans,
## and the partial-recovery marker round-trips.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_home_resources

const SmokeDir = "build/test-tmp/home-apply-smoke"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

suite "Home-apply smoke":

  test "partial-recovery marker round-trips":
    resetDir(SmokeDir)
    writeMarker(SmokeDir, "abcd1234", "in-progress")
    let m = readMarker(SmokeDir)
    check m.present
    check m.generationId == "abcd1234"
    check m.reason == "in-progress"
    clearMarker(SmokeDir)
    let cleared = readMarker(SmokeDir)
    check (not cleared.present)

  test "stow discovery strips GNU stow package level":
    # M73: each immediate subdirectory of `stow/` is a GNU `stow`
    # package; the package name is STRIPPED on materialization. A
    # file directly under `stow/` is a loose file, not materialized.
    let profileDir = SmokeDir / "profile"
    let homeDir = SmokeDir / "home"
    resetDir(profileDir)
    resetDir(homeDir)
    createDir(extendedPath(profileDir / "stow" / "gitpkg"))
    createDir(extendedPath(profileDir / "stow" / "confpkg" / ".config" / "foo"))
    writeFile(extendedPath(profileDir / "stow" / "gitpkg" / ".gitconfig"),
      "[user]\n  email = test@example.com\n")
    writeFile(extendedPath(profileDir / "stow" / "confpkg" / ".config" / "foo" / "bar.toml"),
      "[a]\n")
    # A loose file directly under stow/ — not valid GNU stow layout.
    writeFile(extendedPath(profileDir / "stow" / "loose.txt"), "loose\n")
    let discovery = discoverStowEntries(profileDir, homeDir)
    check discovery.entries.len == 2
    var rels: seq[string]
    var targets: seq[string]
    for e in discovery.entries:
      rels.add e.homeRelativePath
      targets.add e.targetAbsolutePath
    # Package level stripped: `gitpkg`/`confpkg` do NOT appear.
    check ".gitconfig" in rels
    check ".config/foo/bar.toml" in rels
    check (homeDir / ".gitconfig") in targets
    check (homeDir / ".config" / "foo" / "bar.toml") in targets
    # The loose file is reported, not turned into an entry.
    check discovery.looseFiles == @["loose.txt"]

  test "suppression layer pairs stow file with package output":
    var pkgOutput = PlannedGeneratedFile(
      absoluteOutputPath: "/home/u/.gitconfig",
      relativeHomePath: ".gitconfig",
      sourceKind: pgfsPackageOutput,
      contributingPackage: "git-config",
      contentBytes: @[byte('a')])
    var stowEntry = PlannedGeneratedFile(
      absoluteOutputPath: "/home/u/.gitconfig",
      relativeHomePath: ".gitconfig",
      sourceKind: pgfsStowFile,
      stowSourcePath: "/profile/stow/.gitconfig",
      contentBytes: @[byte('s')])
    let contribs = @[ConfigContribution(packageName: "git-config",
      configKey: "userEmail")]
    let res = suppressStowShadowed(@[pkgOutput, stowEntry], contribs)
    check res.files.len == 1
    check res.files[0].sourceKind == pgfsStowFile
    check res.diagnostics.len == 1
    check res.diagnostics[0].code == sdWStowOverridesShadowed
    check "userEmail" in res.diagnostics[0].deadConfigKeys

  test "runApplyPlan fails-closed on a shell-injected resource (M68)":
    # M68 / M69 Phase C: the `--plan` path composes the resource plan
    # via `composePlan` -> `observeResource` -> the observe procs,
    # which SHELL OUT. The pre-dispatch validation gate must therefore
    # fire on the `--plan` path exactly as it does on `runApply`,
    # refusing an operator-controlled field that bears a shell
    # metacharacter BEFORE any observe driver runs. This drives
    # `runApplyPlan` (the `repro home apply --plan` entry point) with
    # an injected `linux.gsettings` resource whose schema carries a
    # `$( ... )` command substitution and asserts it is rejected.
    let profileDir = SmokeDir / "plan-inject-profile"
    let stateDir = SmokeDir / "plan-inject-state"
    let storeRoot = SmokeDir / "plan-inject-store"
    let homeDir = SmokeDir / "plan-inject-home"
    resetDir(profileDir)
    resetDir(stateDir)
    resetDir(storeRoot)
    resetDir(homeDir)
    writeFile(extendedPath(profileDir / "home.nim"),
      "import repro/profile\n\nprofile \"m68-plan-inject\":\n" &
      "  activity default:\n    m68-plan-inject-fixture\n")

    # An injected `linux.gsettings` resource. The `;` is the seam's
    # own field separator, so the metacharacter is a `$( ... )`
    # command substitution embedded in the schema — `$`, `(`, `)` are
    # all in `ShellMetaCharacters`, so `resourceValidationError`
    # refuses it. Seam: gsettings:<address>:<schema>;<path>;<key>;<lit>
    putEnv("REPRO_TEST_RESOURCES",
      "gsettings:g.injected:org.gnome.x$(touch /tmp/pwn);;clock-format;'24h'")
    defer: delEnv("REPRO_TEST_RESOURCES")

    var raised = false
    var sawPreDispatch = false
    var reason = ""
    try:
      discard runApplyPlan(ApplyOptions(
        profileDir: profileDir,
        host: "m68-plan-inject-host",
        stateDir: stateDir,
        storeRoot: storeRoot,
        homeDir: homeDir))
    except EResourceDriver as e:
      raised = true
      # `operation == "pre-dispatch validation"` proves the gate fired
      # BEFORE `composePlan` / `observeGsettings` — an observe-driver
      # failure would carry a different operation tag.
      sawPreDispatch = e.operation == "pre-dispatch validation"
      reason = e.msg
    # The `--plan` preview must REFUSE the unsafe resource.
    check raised
    check sawPreDispatch
    check reason.contains("g.injected")
    check reason.contains("shell metacharacter")

  # ---------------------------------------------------------------------
  # M82 home-scope follow-up: dependency graph + topological sort.
  #
  # These tests drive the home `dep_graph` module directly against a
  # synthesized `seq[Resource]`. They cover the three load-bearing
  # behaviors the integration gate also asserts but at the unit-test
  # layer they pin the graph builder's contracts (cycle refusal,
  # multi-hop chains, stable secondary order) without spinning up the
  # full apply pipeline.
  # ---------------------------------------------------------------------

  test "dep-graph: cyclic depends_on refused with the cycle named":
    # A 3-node cycle A -> B -> C -> A. All three are `fs.managedBlock`
    # so the test is platform-pure.
    let a = Resource(kind: rkFsManagedBlock, address: "A",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/A", managedBlockId: "id-A",
      managedBlockContent: "a",
      dependsOn: @[(kind: "fs.managedBlock", name: "C")])
    let b = Resource(kind: rkFsManagedBlock, address: "B",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/B", managedBlockId: "id-B",
      managedBlockContent: "b",
      dependsOn: @[(kind: "fs.managedBlock", name: "A")])
    let c = Resource(kind: rkFsManagedBlock, address: "C",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/C", managedBlockId: "id-C",
      managedBlockContent: "c",
      dependsOn: @[(kind: "fs.managedBlock", name: "B")])
    var raised = false
    var detail = ""
    try:
      discard orderResourcesTopologically(@[a, b, c])
    except EHomePlanCyclicDependency as e:
      raised = true
      detail = e.msg
      # 3 nodes + 1 closing repetition; first == last.
      check e.cyclePath.len == 4
      check e.cyclePath[0] == e.cyclePath[^1]
      let nodes = e.cyclePath[0 ..< 3]
      check "A" in nodes
      check "B" in nodes
      check "C" in nodes
    check raised
    check "cycle" in detail.toLowerAscii()

  test "dep-graph: multi-hop explicit chain ordered correctly":
    # Declaration order: D, C, B, A (REVERSED). Chain: A -> B -> C -> D
    # (arrow == "must run BEFORE"). Encoded via `depends_on` on B, C, D.
    let d = Resource(kind: rkFsManagedBlock, address: "D",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/D", managedBlockId: "id-D",
      managedBlockContent: "d",
      dependsOn: @[(kind: "fs.managedBlock", name: "C")])
    let c = Resource(kind: rkFsManagedBlock, address: "C",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/C", managedBlockId: "id-C",
      managedBlockContent: "c",
      dependsOn: @[(kind: "fs.managedBlock", name: "B")])
    let b = Resource(kind: rkFsManagedBlock, address: "B",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/B", managedBlockId: "id-B",
      managedBlockContent: "b",
      dependsOn: @[(kind: "fs.managedBlock", name: "A")])
    let a = Resource(kind: rkFsManagedBlock, address: "A",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/A", managedBlockId: "id-A",
      managedBlockContent: "a")
    let sorted = orderResourcesTopologically(@[d, c, b, a])
    check sorted.len == 4
    check sorted[0].address == "A"
    check sorted[1].address == "B"
    check sorted[2].address == "C"
    check sorted[3].address == "D"

  test "dep-graph: independent ops keep declaration order (stable secondary key)":
    # Three independent resources — no edges between them. The
    # emitted order must match the declaration order so the plan is
    # byte-comparable across runs.
    let alpha = Resource(kind: rkFsManagedBlock, address: "alpha",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/alpha", managedBlockId: "id-alpha",
      managedBlockContent: "1")
    let bravo = Resource(kind: rkFsManagedBlock, address: "bravo",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/bravo", managedBlockId: "id-bravo",
      managedBlockContent: "2")
    let charlie = Resource(kind: rkFsManagedBlock, address: "charlie",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/charlie", managedBlockId: "id-charlie",
      managedBlockContent: "3")
    let sorted = orderResourcesTopologically(@[alpha, bravo, charlie])
    check sorted.len == 3
    check sorted[0].address == "alpha"
    check sorted[1].address == "bravo"
    check sorted[2].address == "charlie"
