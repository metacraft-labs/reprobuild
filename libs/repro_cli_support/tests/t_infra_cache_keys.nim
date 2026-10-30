## `repro infra cache-keys`: the entry key an apply derives for a build-action
## edge is a function of the edge and the CONSUMING platform, so a build host
## can derive it for another host and publish ahead of it.
##
## THE NEED. An add-on host that cannot build its own services (rpi2, a
## 32-bit ARM appliance) substitutes every build-action edge's outputs from
## the fleet cache. `buildActionCacheIdentity` keys that lookup by the
## apply host's platform, and `checkCompat` refuses a manifest whose
## platform differs from the host's. So the producer has to publish under a
## key it derives FOR the appliance (its platform, this edge), and record
## that platform in the manifest -- which it can do only if the key is
## derivable off-host. These tests pin that it is, and that the CLI prints
## exactly the key the library derives.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. The library cases run the real
## `buildActionCacheIdentity` / `deriveCacheEntryKeyHex` / `publishIdentityFlags`
## over synthetic `ProfileBuildAction` values: the mirror the profile macro
## emits for an `inlineExecCall(...)`, built by hand because the identity is
## a pure function of those fields and nothing else. The CLI case spawns the
## real `build/bin/repro` on a real `system.nim` and lets it run the real
## profile-compile edge (a real `nim c`), exactly as `repro infra plan`
## would; it then checks the printed key against the library's derivation
## for the same edge. Nothing is mocked.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_binary_cache_client
import repro_binary_cache_client/cli_dispatch as bc_cli
import repro_profile
import repro_profile_compile/binary_cache_build_actions as bc_actions
import repro_cli_support/infra as cli_infra
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc edge(id: string; cwd = "/repro/store/prefixes/example/1";
          outputs: seq[string] = @["bin", "lib"]): ProfileBuildAction =
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", "exit 70"],
    cwd: cwd,
    deps: @[],
    inputs: @[],
    outputs: outputs,
    commandStatsId: "inlineExecCall",
    toolIdentityRefs: @[],
    requiresElevation: true,
    cacheable: true)

proc triple(cpu: string): PlatformTriple =
  PlatformTriple(cpu: cpu, os: "linux", abi: "gnu", libcVariant: "")

suite "repro infra cache-keys: identity for a named platform":

  test "the key is the apply's key with the platform swapped":
    # The explicit-platform derivation and the apply's own (local-platform)
    # derivation agree when given the same platform; the apply path is the
    # one `trySubstituteBuildAction` uses, so this is the equality that
    # makes a published-ahead entry findable.
    let a = edge("searxng-prefix")
    let local = bc_actions.localPlatformTriple("")
    check deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(a, local)) ==
      deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(a, ""))

  test "two platforms derive two keys for one edge":
    let a = edge("searxng-prefix")
    let armKey = deriveCacheEntryKeyHex(
      bc_actions.buildActionCacheIdentity(a, triple("armv7")))
    let x86Key = deriveCacheEntryKeyHex(
      bc_actions.buildActionCacheIdentity(a, triple("x86_64")))
    check armKey.len == 64
    check armKey != x86Key

  test "the identity is the documented tuple":
    # What `repro cache publish` must be told: the package name is the
    # prefixed action id, the fingerprint sits in both the provider
    # revision and the toolchain extra, and the platform is the one given.
    let a = edge("llm-api-proxy-prefix", outputs = @["bin"])
    let idy = bc_actions.buildActionCacheIdentity(a, triple("armv7"))
    check idy.packageName == "infra-apply-action.llm-api-proxy-prefix"
    check idy.packageVersion == "1"
    check idy.platform.cpu == "armv7"
    check idy.platform.os == "linux"
    check idy.toolchain.name == "infra-apply"
    check idy.toolchain.extraFingerprint.len == 64
    check idy.providerRevision == idy.toolchain.extraFingerprint
    check idy.depClosure.len == 0

  test "the fingerprint ignores where the scratch cwd is":
    # Two applies of the same profile from different roots must look up
    # the same entry (the M4 invariant); a published-ahead entry relies on
    # it too, because the producer's cwd is never the consumer's.
    let a = edge("x", cwd = "/repro/store/prefixes/x/1")
    let b = edge("x", cwd = "/var/tmp/elsewhere")
    check deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(a, triple("armv7"))) ==
      deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(b, triple("armv7")))

  test "a changed output set is a different key":
    let a = edge("x", outputs = @["bin"])
    let b = edge("x", outputs = @["bin", "lib"])
    check deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(a, triple("armv7"))) !=
      deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(b, triple("armv7")))

  test "the publish flags reproduce the identity":
    let a = edge("searxng-prefix")
    let idy = bc_actions.buildActionCacheIdentity(a, triple("armv7"))
    let flags = bc_actions.publishIdentityFlags(idy)
    # Every field the key folds in is named, in the spelling the
    # `repro cache` dispatcher parses.
    check "--package-name=infra-apply-action.searxng-prefix" in flags
    check "--package-version=1" in flags
    check "--platform-cpu=armv7" in flags
    check "--platform-os=linux" in flags
    check "--platform-abi=gnu" in flags
    check "--platform-libc=" in flags
    check "--toolchain-name=infra-apply" in flags
    check "--toolchain-version=1" in flags
    check ("--toolchain-extra=" & idy.toolchain.extraFingerprint) in flags
    check ("--provider-revision=" & idy.providerRevision) in flags
    # Round trip through the dispatcher's own parser: the flags derive the
    # same key the apply derives.
    check deriveCacheEntryKeyHex(bc_cli.identityFromPublishFlags(flags)) ==
      deriveCacheEntryKeyHex(idy)

  test "an edge with an output outside cwd is reported as not substitutable":
    let a = edge("x", outputs = @["/etc/elsewhere/file"])
    check not bc_actions.isSubstitutable(a)
    let report = cli_infra.renderCacheKeys(@[a], triple("armv7"))
    check "not substitutable" in report
    check "entry-key" notin report

  test "the report names each substitutable edge with its key and flags":
    let a = edge("searxng-prefix")
    let report = cli_infra.renderCacheKeys(@[a], triple("armv7"))
    let key = deriveCacheEntryKeyHex(
      bc_actions.buildActionCacheIdentity(a, triple("armv7")))
    check ("entry-key: " & key) in report
    check ("repro cache publish " & key & " <prefix> --package-name=infra-apply-action.searxng-prefix") in report

# ---------------------------------------------------------------------------
# CLI round trip against a real compiled profile.
# ---------------------------------------------------------------------------

const ProfileTemplate = """
import repro_profile

profile "cacheKeysProbe":
  resources:
    inlineExecCall(
      argv = @["/bin/sh", "-c", "exit 70"],
      cwd = "/repro/store/prefixes/probe/1",
      outputs = @["bin", "lib"],
      requiresElevation = true,
      address = "probe-prefix",
      commandStatsId = "inlineExecCall")
"""

proc reproBinary(): string =
  result = RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc runRepro(args: seq[string]): tuple[exitCode: int; output: string] =
  var childEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    childEnv[k] = v
  childEnv["REPROBUILD_REPO_ROOT"] = RepoRoot
  var p = startProcess(reproBinary(), args = args, env = childEnv,
                       options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()

suite "repro infra cache-keys: the CLI prints the library's key":

  test "t_infra_cache_keys_cli_round_trip":
    let tmpRoot = createTempDir("infra-cache-keys-", "")
    defer:
      try: removeDir(tmpRoot) except CatchableError: discard
    let stateDir = tmpRoot / "state"
    let profilePath = tmpRoot / "profile" / "system.nim"
    createDir(stateDir)
    createDir(profilePath.parentDir)
    writeFile(profilePath, ProfileTemplate)
    let run = runRepro(@["infra", "cache-keys",
      "--profile", profilePath, "--state-dir", stateDir,
      "--platform-cpu=armv7", "--platform-os=linux",
      "--platform-abi=gnu", "--platform-libc="])
    if run.exitCode != 0:
      echo run.output
    check run.exitCode == 0
    # The edge as the profile macro mirrors it: `address` is the id and
    # `inlineExecCall` is the stats id (both given explicitly above so the
    # mirror is not left to defaults).
    let expected = deriveCacheEntryKeyHex(bc_actions.buildActionCacheIdentity(
      ProfileBuildAction(
        id: "probe-prefix",
        argv: @["/bin/sh", "-c", "exit 70"],
        cwd: "/repro/store/prefixes/probe/1",
        outputs: @["bin", "lib"],
        commandStatsId: "inlineExecCall",
        requiresElevation: true,
        cacheable: true),
      triple("armv7")))
    check ("entry-key: " & expected) in run.output
    check "platform: cpu=armv7 os=linux abi=gnu libc=" in run.output
    # Positive control: the same profile for this host derives a DIFFERENT
    # key (unless this host is itself armv7), so the platform flag is what
    # moved the key, not a constant.
    let localRun = runRepro(@["infra", "cache-keys",
      "--profile", profilePath, "--state-dir", stateDir])
    check localRun.exitCode == 0
    if bc_actions.localPlatformTriple("").cpu != "armv7":
      check ("entry-key: " & expected) notin localRun.output
