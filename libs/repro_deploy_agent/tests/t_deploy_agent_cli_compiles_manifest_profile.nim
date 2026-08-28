## Windows-Runner-Binary-Cache-Deploy M5 — the deploy agent's PRODUCTION
## profile-resolver wiring, driven through the real `repro deploy-agent`
## CLI.
##
## WHY THIS GATE EXISTS.
##
## `mkRunInfraApplyHook` takes an optional `ProfileResolver`. Exactly one
## caller injects one: `repro_cli_support/deploy_agent.nim`, which builds
## the closure that stages a manifest's `profileText` as
## `manifest_profile.nim` and runs it through `resolveSystemProfileText`
## — the same Phase-F3 compile-then-adapt step `repro infra apply` uses.
##
## That caller had NO test. The sibling M5 gate
## `t_repro_deploy_agent_converges_from_signed_manifest` builds a manifest
## with `profileText: ""` plus real build actions — the exact shape that
## later broke — but constructs the hook WITHOUT a resolver, so it stayed
## green while the resolver-carrying production path failed every such
## manifest with
##
##   repro __repro-compile-profile: failed to encode RBPI envelope from
##   compiled profile output: input(1, 0) Error: { expected
##
## A gate that never injects the thing production always injects is not
## covering production. This one injects it the only way that cannot
## drift: it runs the shipped binary.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED.
##
## Nothing is mocked. Per the workspace policy on mocks, the list is
## empty by construction: the test generates a real ECDSA-P256 keypair,
## writes a real signed manifest, and spawns the real `build/bin/repro`
## with `deploy-agent`. The agent does its own polling, signature
## verification, monotonic sequence check, profile compile (a real
## `nim c` through the real `__repro-compile-profile` helper edge) and
## apply. The only injected values are paths — a temp state dir, a temp
## cache root, and `REPROBUILD_REPO_ROOT` so the staged profile can
## resolve `import repro_profile`, which is precisely what a deployed
## host sets too.
##
## The three cases pin the three distinct answers the resolver seam owes:
##
##   1. `profileText: ""` + real build actions -> the resolver is SKIPPED
##      (there is no profile to compile), the build actions still run,
##      and the tick converges. Asserted structurally:
##      `manifest_profile.nim` is never staged and no `profile-cache/`
##      is ever created, so "the resolver did not run" is observed, not
##      assumed.
##   2. a manifest carrying a REAL profile -> the resolver RUNS, the
##      profile compiles (an RBPI envelope lands in the state dir's
##      profile cache), and the compiled profile's own action edges are
##      the ones dispatched.
##   3. a profile whose binary compiles, exits 0, and prints NOTHING ->
##      the structural "printed no ProfileIntent" diagnostic, NOT
##      `parseJson`'s `input(1, 0) Error: { expected`, which names a
##      position in a document that does not exist.
##
## The profiles here declare no live-state resources on purpose. Every
## system-resource kind is privileged, so a live-state create would send
## the apply's LIVE-STATE half to the elevation broker, and a test must
## not raise an elevation prompt on the machine running it. The
## build-action half — the half this seam feeds — takes the in-process
## broker fast path and mutates nothing outside its temp cwd.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_deploy_agent
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile

const Target = "deploy-agent-resolver-target"

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir

const ActionEdgeProfileTemplate = """
import repro_profile

profile "deployAgentManifestProfile":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "@CMD@"],
      cwd = "@CWD@",
      outputs = @["@OUT@"],
      requiresElevation = true,
      address = "writeFromProfile",
      commandStatsId = "m5.resolver.profile.write")
"""

proc reproBinary(): string =
  result = RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc actionEdgeProfileText(cwd, outDir, outRel, payload: string): string =
  ## A real `system.nim`: it imports the DSL, goes through the `profile`
  ## macro, and declares one action edge that writes an observable file.
  ## No live-state resources — see the header note on why a test must
  ## not create any.
  ##
  ## `requiresElevation = true` is what a deployed profile's edges carry,
  ## and it is also what keeps this hermetic: the engine hands an
  ## elevated edge to the apply's `brokerSpawn` closure instead of its
  ## monitored-spawn path, which would otherwise refuse with "automatic
  ## monitor dependency gathering requires an io-monitor driver". Same
  ## reason the sibling M5 gate's actions carry it.
  ##
  ## The shell command is kept free of double quotes so it survives
  ## verbatim into a Nim string literal in the generated profile.
  let cmd = "mkdir -p " & outDir & "; printf '%s' '" & payload &
    "' > '" & outRel & "'"
  ActionEdgeProfileTemplate.multiReplace(
    ("@CMD@", cmd), ("@CWD@", cwd), ("@OUT@", outRel))

proc writeManifestFile(path: string; m: DeployManifest) =
  let bytes = encodeManifest(m)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  writeFile(path, s)

proc shellWriteAction(id, cwd, outDir, outRel, payload: string):
    ProfileBuildAction =
  ## A manifest-carried build action that writes ``payload`` to the
  ## cwd-relative ``outRel``. ``requiresElevation = true`` routes it
  ## through the in-process broker fast path (no monitor CLI needed),
  ## matching the sibling M5 gate's shape.
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c",
            "mkdir -p " & outDir & "; printf '%s' '" & payload &
              "' > '" & outRel & "'"],
    cwd: cwd,
    deps: @[],
    inputs: @[],
    outputs: @[outRel],
    commandStatsId: "m5.resolver.write",
    toolIdentityRefs: @[],
    requiresElevation: true,
    cacheable: true)

type AgentRun = object
  exitCode: int
  output: string   ## stdout + stderr, interleaved as an operator sees them

proc runDeployAgent(stateDir, cacheRoot, manifestPath, signersPath: string):
    AgentRun =
  ## One `repro deploy-agent` tick, exactly as a service timer invokes it.
  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    childEnv[k] = v
  # What a deployed host sets: the repo root the staged profile compiles
  # against. `compileAndAdaptSystemProfile` reads it from the environment.
  childEnv["REPROBUILD_REPO_ROOT"] = RepoRoot
  # Keep the tick off any binary cache the developer's shell configured —
  # this gate is about the resolver seam, not about substitution.
  childEnv.del("REPRO_BINARY_CACHE_URL")
  # A per-case action-cache root so a previous run cannot decide the
  # outcome of this one.
  childEnv["REPROBUILD_ACTION_CACHE_ROOT"] = cacheRoot / "action-cache"
  var p = startProcess(reproBinary(),
    args = @["deploy-agent",
             "--target", Target,
             "--manifest", manifestPath,
             "--allowed-signers", signersPath,
             "--state-dir", stateDir,
             "--cache-root", cacheRoot,
             "--host", "m5-resolver-host"],
    env = childEnv,
    options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()

proc readIfExists(path: string): string =
  ## Reading a missing file raises and takes the whole suite down with
  ## it, hiding every case after this one. The `fileExists` check next
  ## to each call site is the assertion; this keeps a failure reported
  ## rather than fatal.
  if fileExists(path): readFile(path) else: ""

proc stagedProfilePath(stateDir: string): string =
  ## The path the production resolver writes BEFORE it invokes the
  ## compiler. Its presence is the observable "the resolver ran".
  stateDir / "deploy-agent" / "manifest_profile.nim"

proc rbpiArtifactCount(stateDir: string): int =
  ## How many RBPI envelopes the profile-compile edge published under
  ## this state dir — the observable "a profile actually compiled".
  let cacheDir = stateDir / "profile-cache"
  if not dirExists(cacheDir):
    return 0
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.endsWith(".rbpi"):
      inc result

suite "M5 — deploy agent CLI compiles a manifest's profile":

  setup:
    let tmpRoot = createTempDir("m5-resolver-", "")
    let stateDir = tmpRoot / "agent-state"
    let cacheRoot = tmpRoot / "apply-cache"
    let applyCwd = tmpRoot / "target"
    let manifestPath = tmpRoot / "manifests" / "latest.rdm"
    let signersPath = tmpRoot / "allowed-signers"
    createDir(stateDir); createDir(cacheRoot); createDir(applyCwd)
    let signer = peerAuth.generateKeypair()
    peerAuth.writeTrustAnchors(signersPath,
      anchorsFromKeypairs(@[signer.publicKey]))

  teardown:
    try: removeDir(tmpRoot)
    except CatchableError: discard

  test "an empty profileText is not a failed compile":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      const OutRel = "bin/converged.txt"
      const Payload = "converged-with-no-profile"
      var m = DeployManifest(
        target: Target,
        sequence: 10'u64,
        deploymentId: "deploy-empty-profile",
        profileText: "",
        buildActions: @[shellWriteAction(
          "resolver-edge-empty", applyCwd, "bin", OutRel, Payload)])
      signManifest(signer, m)
      writeManifestFile(manifestPath, m)

      let run = runDeployAgent(stateDir, cacheRoot, manifestPath, signersPath)

      # THE REGRESSION SIGNATURE. `input(1, 0)` is `parseJson`'s report
      # for EMPTY input specifically, and it is what this manifest shape
      # produced once the hook started applying the resolver
      # unconditionally. Naming it here means a re-regression is
      # identified by the exact string an operator would paste, not by a
      # generic "the tick failed".
      check "input(1, 0)" notin run.output
      check "profile did not compile" notin run.output
      check run.exitCode == 0
      check "outcome      : aoApplied" in run.output

      # The resolver did NOT run: nothing was staged for the compiler and
      # nothing was published to the profile cache. Observed, not assumed.
      check not fileExists(stagedProfilePath(stateDir))
      check rbpiArtifactCount(stateDir) == 0

      # CONVERGENCE: the manifest's build-action half still did its work.
      check fileExists(applyCwd / OutRel)
      check readIfExists(applyCwd / OutRel) == Payload

  test "a manifest carrying a real profile is compiled and applied":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      const OutRel = "bin/from-profile.txt"
      const Payload = "converged-from-a-compiled-profile"
      # The manifest carries NO `buildActions` of its own, so the edge
      # that runs can only have come from the COMPILED profile — which
      # is the half of the resolver contract worth proving.
      let profileText = actionEdgeProfileText(applyCwd, "bin", OutRel, Payload)
      var m = DeployManifest(
        target: Target,
        sequence: 10'u64,
        deploymentId: "deploy-real-profile",
        profileText: profileText,
        buildActions: @[])
      signManifest(signer, m)
      writeManifestFile(manifestPath, m)

      let run = runDeployAgent(stateDir, cacheRoot, manifestPath, signersPath)

      check "profile did not compile" notin run.output
      check run.exitCode == 0
      check "outcome      : aoApplied" in run.output

      # The resolver RAN: it staged the manifest's text verbatim for the
      # compiler...
      check fileExists(stagedProfilePath(stateDir))
      check readIfExists(stagedProfilePath(stateDir)) == profileText
      # ...and the profile really compiled — an RBPI envelope was
      # published, which only happens on a successful compile edge.
      check rbpiArtifactCount(stateDir) == 1

      # The compiled profile's OWN action edge ran.
      check fileExists(applyCwd / OutRel)
      check readIfExists(applyCwd / OutRel) == Payload

  test "a profile that prints no intent is named as such, not as bad JSON":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      const OutRel = "bin/must-not-appear.txt"
      # Compiles, links, exits 0, prints nothing: the module never
      # reaches the ProfileIntent emitter. Non-blank, so the resolver
      # runs — this is NOT the empty-profileText case above.
      let profileText = "# a profile that never reaches the intent emitter\n"
      var m = DeployManifest(
        target: Target,
        sequence: 10'u64,
        deploymentId: "deploy-silent-profile",
        profileText: profileText,
        buildActions: @[shellWriteAction(
          "resolver-edge-silent", applyCwd, "bin", OutRel,
          "should-not-apply")])
      signManifest(signer, m)
      writeManifestFile(manifestPath, m)

      let run = runDeployAgent(stateDir, cacheRoot, manifestPath, signersPath)

      # A genuine failure — the tick must not report success for a
      # profile whose emitter never ran.
      check run.exitCode == 1
      check "outcome      : aoApplyFailed" in run.output
      # ...but it must be named STRUCTURALLY. The old message pointed at
      # line 1, column 0 of a document that does not exist and sent the
      # reader hunting for a syntax error in a profile that has none.
      check "printed no ProfileIntent JSON" in run.output
      check "input(1, 0)" notin run.output

      # The resolver ran and refused before any apply: the manifest's
      # build action never fired.
      check fileExists(stagedProfilePath(stateDir))
      check not fileExists(applyCwd / OutRel)
