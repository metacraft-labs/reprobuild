## Real decoder fixtures run in fresh processes so peak-memory assertions cannot
## be hidden by the high-water mark of an earlier malformed record.
import std/[os, osproc, strutils, tempfiles, unittest]
import blake3
import repro_core
import repro_store_daemon/protocol
import repro_launch_plan/[codec, types]
import repro_home_generations/[manifest, activation_bundle, intent_snapshot, pointer, errors]
import repro_cmake_trycompile
import repro_tool_profiles as profiles
import repro_local_store/store as store
import repro_resources/protocol as resourceProtocol
import repro_resources/[resource_graph, instance]
import repro_project_dsl as dsl
import repro_binary_cache_server/manifest_codec as cache
import repro_binary_cache_server/types as cacheTypes
import repro_deploy_agent/manifest as deploy
import repro_profile as profile
import repro_dsl_stdlib/configurables/rbcg as config
import repro_dsl_stdlib/configurables/types as configTypes
import repro_binary_cache_client/in_process as cacheClient
import repro_deploy_agent/secrets as deploySecrets
import repro_peer_cache/action_bundle as peerBundle



proc corruptCount(bytes: var seq[byte]; offset: int; checksum: bool) =
  for i in 0 ..< 4:
    bytes[offset + i] = byte((65536'u32 shr (8 * i)) and 255)
  if checksum:
    let digest = blake3.digest(bytes.toOpenArray(0, bytes.len - 33))
    for i in 0 ..< 32: bytes[bytes.len - 32 + i] = digest[i]

template boundedDecode(errorType: typedesc; expression: untyped) =
  let before = getMaxMem()
  var rejected = false
  try:
    discard expression
  except errorType as error:
    doAssert "element count" in error.msg, "wrong rejection: " & error.msg
    rejected = true
  doAssert rejected, "malformed count was accepted"
  doAssert getMaxMem() - before < 512 * 1024,
    "decoder allocated from an impossible element count"

proc exercise(family: string; offset: int) =
  case family
  of "store":
    var bytes = externalRealizeBody(StoreDaemonExternalRealizeRequest())
    bytes.corruptCount(offset, false)
    boundedDecode(EnvelopeError, parseExternalRealizeBody(bytes))
  of "launch":
    var bytes = encodeLaunchPlan(LaunchPlan(schemaVersion: LaunchPlanCurrentSchemaVersion))
    bytes.corruptCount(offset, true)
    boundedDecode(LaunchPlanCodecError, decodeLaunchPlan(bytes))
  of "manifest":
    var bytes = manifest.encodeManifest(ActivationManifest())
    bytes.corruptCount(offset, true)
    boundedDecode(EManifestCorrupt, decodeManifestBytes(bytes))
  of "snapshot":
    var bytes = encodeSnapshot(IntentSnapshot())
    bytes.corruptCount(offset, true)
    boundedDecode(EIntentSnapshotCorrupt, decodeSnapshotBytes(bytes))
  of "bundle":
    var bytes = encodeActivationBundle(ActivationBundle())
    bytes.corruptCount(offset, true)
    boundedDecode(EActivationBundleCorrupt, decodeActivationBundleBytes(bytes))
  of "bundleFiles":
    var bytes = encodeActivationBundle(ActivationBundle(prefixes: @[
      ActivationBundlePrefixClosure(storeRelativePath: "a")]))
    bytes.corruptCount(offset, true)
    boundedDecode(EActivationBundleCorrupt, decodeActivationBundleBytes(bytes))
  of "cmake":
    var bytes = encodeTryCompileMetadata(TryCompileMetadata())
    bytes.corruptCount(offset, false)
    boundedDecode(TryCompileMetadataError, decodeTryCompileMetadata(bytes))
  of "profiles":
    var bytes = profiles.encodePathOnlyBuildIdentity(profiles.PathOnlyBuildIdentity())
    bytes.corruptCount(offset, false)
    boundedDecode(EnvelopeError, profiles.decodePathOnlyBuildIdentity(bytes))
  of "receipt":
    var bytes = store.encodeReceipt(store.RealizationReceipt())
    bytes.corruptCount(offset, true)
    boundedDecode(store.EReceiptCorrupt, store.decodeReceipt(bytes))
  of "resource":
    let inst = ResourceInstance(attrs: dsl.RawExtensionBox())
    var bytes = resourceProtocol.encodeResourceInstance(inst)
    bytes.corruptCount(offset, false)
    boundedDecode(EnvelopeError, resourceProtocol.decodeResourceInstance(bytes))
  of "resourceGraph":
    var bytes = encodeResourceGraphPayload(@[], @[])
    bytes.corruptCount(offset, false)
    boundedDecode(EnvelopeError, decodeResourceGraphPayload(bytes))
  of "resourceMembers":
    var bytes = encodeResourceGraphPayload(@[], @[dsl.StateGroupDef()])
    bytes.corruptCount(offset, false)
    boundedDecode(EnvelopeError, decodeResourceGraphPayload(bytes))
  of "resourceLength":
    var bytes = encodeResourceGraphPayload(@[ResourceInstance(attrs: dsl.RawExtensionBox())], @[])
    bytes.corruptCount(offset, false)
    boundedDecode(EnvelopeError, decodeResourceGraphPayload(bytes))
  of "cache":
    var bytes = cache.encodeManifest(cacheTypes.BinaryCacheManifest(formatVersion: cacheTypes.BinaryCacheFormatVersion))
    var at = 40
    let keyLength = int(readU32Le(bytes, at))
    let actualOffset = if offset < 0: 44 + keyLength + (-offset - 1) else: offset
    bytes.corruptCount(actualOffset, false)
    boundedDecode(cache.BinaryCacheCodecError, cache.decodeManifest(bytes))
  of "deploy":
    var bytes = deploy.encodeManifest(deploy.DeployManifest(buildActions: @[profile.ProfileBuildAction()]))
    bytes.corruptCount(offset, false)
    boundedDecode(deploy.DeployManifestCodecError, deploy.decodeManifest(bytes))
  of "rbcg":
    let ctx = configTypes.ConfigContext(state: configTypes.ccsFinalized, nodes: @[
      configTypes.ConfigurableNode(contributions: @[configTypes.Contribution()], deps: @[0'u64])])
    var bytes = config.encodeRbcg(ctx)
    bytes.corruptCount(offset, true)
    boundedDecode(configTypes.ECorruptEnvelope, config.decodeRbcg(bytes))
  of "secrets":
    var bytes = deploySecrets.encodeSecretFiles(@[])
    bytes.corruptCount(offset, false)
    boundedDecode(deploySecrets.SecretsError, deploySecrets.decodeSecretFiles(bytes))
  of "actionBundle":
    # The blob count follows the magic, version, record length and the
    # encoded record itself; the case offset is relative to that point.
    var bytes = peerBundle.encodeActionBundle(peerBundle.ActionBundle())
    var at = 6
    let recordLength = int(readU32Le(bytes, at))
    bytes.corruptCount(10 + recordLength + offset, false)
    boundedDecode(ValueError, peerBundle.decodeActionBundle(bytes))
  of "archiveLength":
    var bytes = toBytes("RBCA")
    bytes.writeU32Le(1)
    bytes.writeU32Le(1)
    bytes.writeString("a")
    bytes.writeU32Le(0)
    bytes.writeU64Le(high(uint64))
    let outDir = createTempDir("binary-decoder-count-", "")
    defer: removeDir(outDir)
    let before = getMaxMem()
    var rejected = false
    try:
      cacheClient.extractPrefix(bytes, outDir)
    except IOError as error:
      doAssert "truncated reading file body" in error.msg
      rejected = true
    doAssert rejected
    doAssert getMaxMem() - before < 512 * 1024
  else: doAssert false

if paramCount() == 3 and paramStr(1) == "count-case":
  exercise(paramStr(2), parseInt(paramStr(3)))
  quit(0)

proc runCase(family: string; offset: int) =
  let child = execCmdEx(quoteShell(getAppFilename()) & " count-case " &
    quoteShell(family) & " " & $offset)
  checkpoint child.output
  check child.exitCode == 0

suite "binary collection counts are bounded before allocation":
  test "store daemon mirror and prune lists":
    for offset in [60, 76]: runCase("store", offset)
  test "launch arguments environment executables and runtime paths":
    for offset in [24, 33, 37, 41]: runCase("launch", offset)
  test "activation manifest collections":
    for offset in [10, 14, 18, 22, 26]: runCase("manifest", offset)
  test "intent snapshot files":
    runCase("snapshot", 10)
  test "activation bundle blobs prefixes and nested files":
    for offset in [82, 86]: runCase("bundle", offset)
    runCase("bundleFiles", 135)
  test "trycompile tools pools actions targets and configuration lists":
    for offset in [10, 14, 18, 22, 30, 34, 38, 42]: runCase("cmake", offset)
  test "tool profile and action identity counts":
    for offset in [48, 52]: runCase("profiles", offset)
  test "receipt executable output and prune counts":
    for offset in [64, 108, 120]: runCase("receipt", offset)
  test "resource instance graph and group counts and nested record length":
    runCase("resource", 16)
    for offset in [10, 14]: runCase("resourceGraph", offset)
    runCase("resourceMembers", 22)
    runCase("resourceLength", 14)
  test "binary cache options payloads and dependencies":
    for offset in [54, -1, -37]: runCase("cache", offset)
  test "deploy actions and nested argument dependency input output tool lists":
    for offset in [28, 36, 44, 48, 52, 60]: runCase("deploy", offset)
  test "configurable nodes contributions and dependencies":
    for offset in [12, 44, 64]: runCase("rbcg", offset)
  test "deploy secret file list":
    runCase("secrets", 0)
  test "peer action bundle blob list":
    runCase("actionBundle", 0)
  test "archive uint64 size is checked before narrowing":
    runCase("archiveLength", 0)
  test "valid nonempty collections still roundtrip":
    let plan = LaunchPlan(schemaVersion: LaunchPlanCurrentSchemaVersion,
      arguments: @[""], environmentBindings: @[EnvBinding()],
      executableBindings: @[ExecutableBinding()], runtimeLibraryDirs: @[""])
    check decodeLaunchPlan(encodeLaunchPlan(plan)) == plan
    let manifest = ActivationManifest(realizedPackages: @[RealizedPackage()],
      exportedCommands: @[ExportedCommand()], generatedFiles: @[GeneratedFile()],
      managedBlocks: @[ManagedBlock()], resourceBindings: @[manifest.ResourceBinding()])
    let decoded = decodeManifestBytes(manifest.encodeManifest())
    check decoded.realizedPackages.len == 1
    check decoded.exportedCommands.len == 1
    check decoded.generatedFiles.len == 1
    check decoded.managedBlocks.len == 1
    check decoded.resourceBindings.len == 1
    let snap = IntentSnapshot(files: @[IntentFileEntry(path: "a", content: @[1'u8])])
    check decodeSnapshotBytes(encodeSnapshot(snap)).files == snap.files
    let meta = TryCompileMetadata(usedTools: @[""], pools: @[TryCompilePoolDef()],
      actions: @[TryCompileActionDef()], targets: @[TryCompileTargetDef()],
      crossConfigs: @[""], crossConfigTargets: @[CrossConfigTargetDef()],
      defaultConfigs: @[""], actionEnv: @[""])
    check decodeTryCompileMetadata(encodeTryCompileMetadata(meta)).pools.len == 1
    # Exact-fit fixtures for the larger per-element minimums: each list holds
    # one smallest-possible element, so a minimum above the true encoded size
    # would refuse these valid records.
    let secretFiles = @[deploySecrets.SecretFile(path: "a")]
    check deploySecrets.decodeSecretFiles(
      deploySecrets.encodeSecretFiles(secretFiles)).len == 1
    let emptyDigest = blake3.digest(newSeq[byte]())
    let bundle = ActivationBundle(
      casBlobs: @[ActivationBundleCasBlobEntry(digest: emptyDigest)],
      prefixes: @[ActivationBundlePrefixClosure(storeRelativePath: "a",
        files: @[ActivationBundleFileEntry(contentDigest: emptyDigest)])])
    let decodedBundle = decodeActivationBundleBytes(encodeActivationBundle(bundle))
    check decodedBundle.casBlobs.len == 1
    check decodedBundle.prefixes.len == 1
    check decodedBundle.prefixes[0].files.len == 1
    let cacheManifest = cacheTypes.BinaryCacheManifest(
      formatVersion: cacheTypes.BinaryCacheFormatVersion,
      payloads: @[cacheTypes.PayloadObject()],
      depReferences: @[default(cacheTypes.Blake3Hash)])
    let decodedCache = cache.decodeManifest(cache.encodeManifest(cacheManifest))
    check decodedCache.payloads.len == 1
    check decodedCache.depReferences.len == 1
