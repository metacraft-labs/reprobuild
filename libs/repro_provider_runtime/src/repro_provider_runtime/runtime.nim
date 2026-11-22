import std/[algorithm, os, osproc, sets, streams, strutils, tables, times]

when defined(posix):
  import std/posix

import repro_core
import repro_core/portable_release_launch
import repro_hash
import repro_provider_runtime/codec
import repro_provider_runtime/types
import repro_local_store/pattern_scoped_enumeration

type
  InvocationPlan = object
    entryPointId: string
    entryPointBodyHash: string
    arguments: string
    namespace: string
    reason: GraphInvocationReason

const ProviderStartupBodyFailurePrefix* =
  "repro project provider: startup body failed: "
  ## The line a provider writes when a ``build:`` body raised during the
  ## DSL's module-init pass over it.
  ##
  ## Declared on the ENGINE side although the PROVIDER writes it, because
  ## both ends have to agree on the text: the engine reads the provider's
  ## merged output for exactly this prefix and re-emits it (see
  ## ``runProviderProtocol``). Two spellings of it would fail silently --
  ## the provider would report and the engine would drop it -- which is
  ## the failure mode the prefix exists to prevent.

proc raiseRuntime(message: string) {.noreturn.} =
  raise newException(ProviderRuntimeError, message)

proc requireInvocationProjectRoot*(arguments, entryPointId,
                                   providerArtifactId: string) =
  ## A graph invocation's ``arguments`` slot carries the project root the
  ## entry point evaluates against, and a recipe resolves every input and
  ## output it declares against that root.
  ##
  ## Empty is not a value anything downstream checks for. The fragment /
  ## request comparisons only require the two to MATCH, so an empty root
  ## travels intact all the way into a recipe and surfaces as whatever
  ## that recipe's first path resolution happens to raise -- a message
  ## naming neither the invocation nor the package. Refuse it where the
  ## invocation is assembled instead, and name the entry point.
  ##
  ## Called from the two places an invocation's root enters the runtime:
  ## the caller-supplied root of a refresh, and every plan the refresh
  ## then executes (children derive their root from the parent's, but a
  ## plan can also be rebuilt from a stored fragment).
  if arguments.len == 0:
    raiseRuntime("provider graph invocation has no project root: entry " &
      "point '" & entryPointId & "' of provider artifact '" &
      providerArtifactId & "'")

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestHex(payload: openArray[byte]): string =
  toHex(blake3DomainDigest(payload, hdMetadataEnvelope).bytes)

proc digestText(text: string): string =
  digestHex(toBytes(text))

proc argumentDigest*(arguments: string): string =
  digestText(arguments)

proc graphInvocationKey*(projectId, entryPointId, arguments, lockSliceId,
                         activity, namespace: string): string =
  ## The identity of a graph invocation: WHICH invocation owns a stored
  ## fragment, never which build of the provider produced it
  ## (Project-Provider-Graph-Protocol.md §"Graph Fragment").
  ##
  ## It is made of the project, the entry point id, the argument digest, the
  ## lock slice, the activity and the namespace, and nothing else. The
  ## provider artifact id and the entry point body hash are deliberately
  ## absent: they are VALIDITY attributes, recorded on the stored fragment
  ## (``StoredGraphFragment.providerArtifactId`` / ``entryPointBodyHash``,
  ## and the ``gevProviderSource`` input). A mismatch on them makes the
  ## refresh run the invocation again, and the fragment it returns is stored
  ## under this same key, replacing the previous one. That is what lets a
  ## re-produced fragment be compared with the one it replaces -- early
  ## cutoff, stale-edge pruning, stale-effect cleanup -- across a provider
  ## recompile, a recipe body edit or an import-mode switch, and what keeps
  ## two live fragments of one invocation from claiming the same effect.
  ##
  ## A different lock slice or activity IS a different invocation: its
  ## fragments are not the previous ones re-produced, so the previous ones
  ## are pruned.
  ##
  ## Each component is length-prefixed, so no value containing the
  ## separator can make two different invocations share a key.
  for component in [projectId, entryPointId, argumentDigest(arguments),
                    lockSliceId, activity, namespace]:
    if result.len > 0:
      result.add('|')
    result.add($component.len)
    result.add(':')
    result.add(component)

proc devEnvIntrospectionEntryPointId*(projectName: string): string =
  projectName & ".dev-env"

proc computeGraphFragmentDigest*(fragment: GraphFragment): string =
  digestHex(encodeFragmentForDigest(fragment))

proc readProviderRequestFile*(path: string): ProviderGraphRequest =
  decodeProviderRequest(fromByteString(readFile(extendedPath(path))))

proc writeProviderRequestFile*(path: string; request: ProviderGraphRequest) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProviderRequest(request)))

proc readProviderResponseFile*(path: string): ProviderGraphResponse =
  decodeProviderResponse(fromByteString(readFile(extendedPath(path))))

proc writeProviderResponseFile*(path: string; response: ProviderGraphResponse) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProviderResponse(response)))

proc providerSnapshotPath*(storeRoot: string): string =
  storeRoot / "provider-fragments.rbsz"

proc loadProviderGraphSnapshot*(storeRoot: string): ProviderGraphSnapshot =
  ## The provider-fragment cache, or an EMPTY snapshot when there is
  ## nothing this build can read -- which the refresher reads as
  ## "recompute".
  ##
  ## A SNAPSHOT IS A DERIVED CACHE, so an unreadable one must be
  ## DISCARDED AND RECOMPUTED rather than raised. That is the whole of
  ## the rule, and the absent-file arm below has always implemented half
  ## of it; the version arm is the other half. Nothing in
  ## `provider-fragments.rbsz` is anything but the output of an
  ## evaluation this build can run again, and no caller holds an
  ## identifier for a particular snapshot, so throwing one away costs
  ## one evaluation and nothing else.
  ##
  ## WHY THAT IS NOT THE RULE FOR AN ARTIFACT, which is the comparison
  ## that decides it. D-SS11 deliberately version-gates and DECODES the
  ## dev-env artifact: an artifact IS the evaluation's output, addressed
  ## by its content id, and a reader that silently discarded one would
  ## answer with a recomputation whose id the caller had already been
  ## promised. The two rules differ because the two things differ, not
  ## because one lane is stricter than the other.
  ##
  ## AND WHY THIS ARM HAD TO LAND BEFORE THE VERSION MOVED. One
  ## `ProviderGraphVersion` governs all THREE envelope types this
  ## library frames -- request, response and snapshot -- so
  ## Shared-Development-Services F1's change to the RESPONSE
  ## (`DevEnvResult` grew an `actions` list) moves the version for the
  ## SNAPSHOT too, although the snapshot payload layout did not change
  ## at all. Bumping without this arm would therefore have turned every
  ## `provider-fragments.rbsz` already on disk into a hard error at the
  ## next build, for a cache the build was free to rebuild. With the arm
  ## in place the same skew is a named, silent recomputation instead of
  ## the loud-but-unnamed `trailing provider response payload bytes`
  ## that a version-blind decode produced.
  ##
  ## THE ARM IS NARROW, and that is what keeps it from becoming "ignore
  ## every snapshot that will not decode". Only `eeUnsupportedVersion`
  ## is translated. A corrupt magic, a truncated payload, a wrong type
  ## id or trailing bytes still raise, because those do not say "this
  ## cache is from another epoch" -- they say the file is not the thing
  ## it claims to be, and answering real corruption with a silent
  ## recomputation is how it stays invisible.
  let path = providerSnapshotPath(storeRoot)
  if not fileExists(extendedPath(path)):
    return ProviderGraphSnapshot()
  try:
    result = decodeProviderSnapshot(fromByteString(readFile(extendedPath(path))))
  except EnvelopeError as err:
    if err.kind != eeUnsupportedVersion:
      raise
    result = ProviderGraphSnapshot()

proc saveProviderGraphSnapshot*(storeRoot: string; snapshot: ProviderGraphSnapshot) =
  createDir(extendedPath(storeRoot))
  let path = providerSnapshotPath(storeRoot)
  let tmp = storeRoot / ("provider-fragments." & $getCurrentProcessId() & "." &
    $epochTime() & ".tmp")
  writeFile(extendedPath(tmp), toByteString(encodeProviderSnapshot(snapshot)))
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmp), extendedPath(path))

proc parseProviderProtocolArgs*(args: openArray[string]):
    tuple[requestPath: string; responsePath: string] =
  var i = 0
  while i < args.len:
    case args[i]
    of "--repro-provider-request":
      inc i
      if i >= args.len:
        raiseRuntime("missing value for --repro-provider-request")
      result.requestPath = args[i]
    of "--repro-provider-response":
      inc i
      if i >= args.len:
        raiseRuntime("missing value for --repro-provider-response")
      result.responsePath = args[i]
    else:
      discard
    inc i
  if result.requestPath.len == 0 or result.responsePath.len == 0:
    raiseRuntime("provider protocol request/response arguments are required")

proc runProviderProtocol*(config: ProviderExecutionConfig;
                          request: ProviderGraphRequest): ProviderGraphResponse =
  if config.binaryPath.len == 0:
    raiseRuntime("provider binary path is required")
  let tempRoot =
    if config.tempRoot.len > 0: config.tempRoot
    else: getTempDir()
  createDir(extendedPath(tempRoot))
  let stem = "repro-provider-" & $getCurrentProcessId() & "-" & $epochTime()
  let requestPath = tempRoot / (stem & ".request.rbpg")
  let responsePath = tempRoot / (stem & ".response.rbpg")
  defer:
    if fileExists(extendedPath(requestPath)):
      removeFile(extendedPath(requestPath))
    if fileExists(extendedPath(responsePath)):
      removeFile(extendedPath(responsePath))

  writeProviderRequestFile(requestPath, request)

  let tracePath = getEnv("REPRO_PROVIDER_TRACE")
  if tracePath.len > 0:
    createDir(extendedPath(tracePath.splitPath.head))
    var handle = open(extendedPath(tracePath), fmAppend)
    try:
      handle.writeLine(($request.kind) & "|" & request.entryPointId & "|" &
        request.arguments & "|" & $request.reason)
    finally:
      handle.close()

  let cwd =
    if config.workingDir.len > 0: config.workingDir
    else: getCurrentDir()
  # Under the portable Linux release a provider it compiled starts through
  # the bundled loader (`portableReleaseHelperArgv`), or it cannot load the
  # release's clingo on a host glibc older than the release's.
  let argv = portableReleaseHelperArgv(@[config.binaryPath] &
    config.extraArgs & @[
    "--repro-provider-request", requestPath,
    "--repro-provider-response", responsePath], cwd = cwd)
  # Spawn the provider binary DIRECTLY, without an intermediate shell.
  #
  # The earlier form ran the provider via ``execCmdEx`` →
  # ``/bin/sh -c <quoted argv>``. On macOS ``/bin/sh`` is a System
  # Integrity Protection–restricted binary, and dyld purges every
  # ``DYLD_*`` environment variable across an ``exec`` of a restricted
  # binary. So a ``DYLD_LIBRARY_PATH`` the caller exported to make
  # ``libclingo`` discoverable was silently dropped before it could reach
  # the provider: providers transitively import the solver bindings, which
  # ``dlopen`` ``libclingo.dylib`` by leaf name, and the process aborted at
  # startup with ``could not load: libclingo.dylib``. Executing the
  # provider binary directly preserves the caller's environment —
  # including ``DYLD_LIBRARY_PATH`` — so the leaf-name ``dlopen`` resolves.
  #
  # We keep the M8 stderr-truncation fix: ``startProcess +
  # outputStream.readAll`` returned only the first byte of merged stderr on
  # Windows, so we drain incrementally with ``readLine`` until EOF and then
  # ``waitForExit``. ``poStdErrToStdOut`` merges stderr into the single
  # captured stream so one drain catches the provider's diagnostics.
  let process = startProcess(argv[0],
    workingDir = cwd,
    args = argv[1 .. ^1],
    options = {poStdErrToStdOut, poUsePath})
  var output = ""
  block drainProvider:
    let outStream = process.outputStream
    var line = ""
    while outStream.readLine(line):
      output.add(line)
      output.add('\n')
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raiseRuntime("provider exited with code " & $exitCode & ": " & output)
  # A provider that exits 0 has this captured output DROPPED: the pipe is
  # here so a FAILING provider's diagnostics reach the operator inside the
  # refusal above. A contained startup-body failure is the one diagnostic a
  # SUCCEEDING provider can carry, and dropping it would make containment
  # indistinguishable from nothing having gone wrong -- the provider would
  # report a broken recipe into a pipe nobody reads. Forward those lines,
  # and only those, so this cannot become a channel for arbitrary provider
  # chatter.
  for line in output.splitLines():
    if line.startsWith(ProviderStartupBodyFailurePrefix):
      stderr.writeLine(line)
  if not fileExists(extendedPath(responsePath)):
    raiseRuntime("provider did not write a response file")
  readProviderResponseFile(responsePath)

proc manifestById(manifest: ProviderManifest):
    Table[string, GraphEntryPointDescriptor] =
  for descriptor in manifest.entryPoints:
    result[descriptor.id] = descriptor

proc validateManifest(manifest: ProviderManifest; expectedArtifactId: string) =
  if manifest.protocolVersion != ProviderProtocolVersion:
    raiseRuntime("unsupported provider protocol version " &
      $manifest.protocolVersion)
  if expectedArtifactId.len > 0 and manifest.providerArtifactId != expectedArtifactId:
    raiseRuntime("provider manifest artifact mismatch: expected " &
      expectedArtifactId & ", got " & manifest.providerArtifactId)
  var seen = initHashSet[string]()
  for descriptor in manifest.entryPoints:
    if descriptor.id.len == 0:
      raiseRuntime("provider manifest entry point id is required")
    if descriptor.bodyHash.len == 0:
      raiseRuntime("provider manifest body hash is required for " &
        descriptor.id)
    if seen.contains(descriptor.id):
      raiseRuntime("duplicate provider manifest entry point: " & descriptor.id)
    seen.incl(descriptor.id)

proc readProviderManifest*(config: ProviderExecutionConfig;
                           providerArtifactId: string): ProviderManifest =
  let response = runProviderProtocol(config, ProviderGraphRequest(
    kind: prkManifest,
    providerArtifactId: providerArtifactId,
    reason: girExplicitUserRequest))
  if response.kind != pskManifest:
    raiseRuntime("provider manifest request returned a graph result")
  validateManifest(response.manifest, providerArtifactId)
  response.manifest

proc namespacePrefix(namespace: string): string =
  if namespace.len == 0: ""
  else: namespace & ":"

proc edgeKey(edge: types.GraphEdge): string =
  edge.id & "|" & $edge.kind & "|" & edge.fromNode & "|" & edge.toNode

proc validateFragment(fragment: GraphFragment; request: ProviderGraphRequest;
                      manifest: ProviderManifest) =
  if fragment.entryPointId != request.entryPointId:
    raiseRuntime("provider response entry point mismatch")
  if fragment.entryPointBodyHash != request.entryPointBodyHash:
    raiseRuntime("provider response body hash mismatch")
  if fragment.arguments != request.arguments:
    raiseRuntime("provider response arguments mismatch")
  if fragment.namespace != request.namespace:
    raiseRuntime("provider response namespace mismatch")
  if fragment.fragmentDigest.len == 0:
    raiseRuntime("provider response is missing a fragment digest")
  let expectedDigest = computeGraphFragmentDigest(fragment)
  if fragment.fragmentDigest != expectedDigest:
    raiseRuntime("provider response fragment digest mismatch")

  let descriptors = manifestById(manifest)
  if not descriptors.hasKey(fragment.entryPointId):
    raiseRuntime("provider response names an entry point not present in manifest")
  if descriptors[fragment.entryPointId].bodyHash != fragment.entryPointBodyHash:
    raiseRuntime("provider response body hash does not match manifest")

  let prefix = namespacePrefix(fragment.namespace)
  var nodeIds = initHashSet[string]()
  for node in fragment.nodes:
    if node.id.len == 0:
      raiseRuntime("graph node id is required")
    if prefix.len > 0 and not node.id.startsWith(prefix):
      raiseRuntime("graph node outside authorized namespace: " & node.id)
    if nodeIds.contains(node.id):
      raiseRuntime("duplicate graph node id: " & node.id)
    nodeIds.incl(node.id)

  var edgeIds = initHashSet[string]()
  for edge in fragment.edges:
    if edge.id.len == 0:
      raiseRuntime("graph edge id is required")
    if prefix.len > 0 and not edge.id.startsWith(prefix):
      raiseRuntime("graph edge outside authorized namespace: " & edge.id)
    if edgeIds.contains(edge.id):
      raiseRuntime("duplicate graph edge id: " & edge.id)
    if not nodeIds.contains(edge.fromNode) or not nodeIds.contains(edge.toNode):
      raiseRuntime("graph edge references a node outside its fragment")
    edgeIds.incl(edge.id)

  var effects = initHashSet[string]()
  for claim in fragment.effectClaims:
    let key = effectKey(claim)
    if claim.identity.len == 0:
      raiseRuntime("owned effect identity is required")
    if effects.contains(key):
      raiseRuntime("duplicate owned effect claim in fragment: " & key)
    effects.incl(key)

  for child in fragment.childEntryPoints:
    if not descriptors.hasKey(child.entryPointId):
      raiseRuntime("child entry point is not present in manifest: " &
        child.entryPointId)
    if descriptors[child.entryPointId].bodyHash != child.entryPointBodyHash:
      raiseRuntime("child entry point body hash does not match manifest")

proc resolvedResponsePath(path, base: string): string =
  if path.len == 0 or path.isAbsolute or base.len == 0:
    path
  else:
    os.normalizedPath(absolutePath(base) / path)

proc resolvedResponseSite(site, base: string): string =
  ## A rendered `<file>:<line>` source site (`DevEnvSharedResolution.
  ## contributionSites`) with its file resolved as `resolvedResponsePath`
  ## resolves a bare path. The line is everything after the LAST colon, so
  ## a file name that itself contains a colon keeps it.
  let colon = site.rfind(':')
  if colon <= 0:
    return resolvedResponsePath(site, base)
  resolvedResponsePath(site[0 ..< colon], base) & site[colon .. ^1]

proc resolveResponseInputs(inputs: var seq[GraphEvaluationInput];
                           base: string): bool =
  for input in inputs.mitems:
    if input.kind in {gevFileRead, gevDirectoryEnumeration}:
      let resolved = resolvedResponsePath(input.identity, base)
      if resolved != input.identity:
        input.identity = resolved
        result = true

proc resolveRelativeResponsePaths*(response: var ProviderGraphResponse;
                                   workingDir: string) =
  ## Provider-Runtime-Protocol-v1.md, "Paths in responses": a provider names
  ## the recipe's own files RELATIVE to the recipe it was compiled from — a
  ## recipe-relative provider compile is served to every copy of the recipe,
  ## and the binary cannot know where it runs (`recipeSourceName`). The
  ## engine launched it with `workingDir` = that copy's project root, so this
  ## is where those names resolve. Applied when a response is received, so
  ## every reader of a fragment or dev-env result — a snapshot's freshness
  ## check above all — sees the absolute file of THIS copy. A fragment's
  ## digest is recomputed after its validation against the provider's own.
  if workingDir.len == 0:
    return
  case response.kind
  of pskGraphResult:
    if resolveResponseInputs(response.fragment.evaluationInputs, workingDir) and
        response.fragment.fragmentDigest.len > 0:
      response.fragment.fragmentDigest =
        computeGraphFragmentDigest(response.fragment)
  of pskDevEnvResult:
    discard resolveResponseInputs(response.devEnv.evaluationInputs, workingDir)
    for fingerprint in response.devEnv.sourceFingerprints.mitems:
      if fingerprint.kind == "provider-source":
        fingerprint.identity =
          resolvedResponsePath(fingerprint.identity, workingDir)
    for diagnostic in response.devEnv.diagnostics.mitems:
      diagnostic.sourceFile =
        resolvedResponsePath(diagnostic.sourceFile, workingDir)
    # A shared-service resolution names the resolver's site, its
    # contributions' sites and the OWNER's recipe directory, all as the
    # provider's DSL recorded them: relative to the recipe the provider was
    # compiled from when they lie outside the anchors (a sibling owner is
    # `../<owner>`, the provider's own package is `.`). The engine reads
    # `ownerRecipeDir` to find the owner's interface artifact, so it must
    # name THIS copy's owner, never the copy that compiled the provider.
    for resolution in response.devEnv.sharedResolutions.mitems:
      resolution.ownerRecipeDir =
        resolvedResponsePath(resolution.ownerRecipeDir, workingDir)
      resolution.sourceFile =
        resolvedResponsePath(resolution.sourceFile, workingDir)
      for site in resolution.contributionSites.mitems:
        site = resolvedResponseSite(site, workingDir)
  of pskManifest:
    discard

proc invokeProviderEntryPoint*(config: ProviderExecutionConfig;
                               request: ProviderGraphRequest): ProviderGraphResponse =
  var response = runProviderProtocol(config, request)
  if response.kind != pskGraphResult:
    raiseRuntime("provider graph request returned a manifest response")
  validateManifest(response.manifest, request.providerArtifactId)
  validateFragment(response.fragment, request, response.manifest)
  response.resolveRelativeResponsePaths(
    if config.workingDir.len > 0: config.workingDir else: getCurrentDir())
  response

proc splitActivities(activity: string): seq[string] =
  for item in activity.split(','):
    let stripped = item.strip()
    if stripped.len > 0:
      result.add(stripped)

proc validateDevEnvResult(devEnv: DevEnvResult; request: ProviderGraphRequest;
                          manifest: ProviderManifest) =
  if devEnv.schemaVersion == 0'u32:
    raiseRuntime("provider dev-env result is missing a schema version")
  if devEnv.providerArtifactId != request.providerArtifactId:
    raiseRuntime("provider dev-env artifact id mismatch")
  if devEnv.providerEntryPointId != request.entryPointId:
    raiseRuntime("provider dev-env entry point mismatch")
  if devEnv.providerEntryPointBodyHash != request.entryPointBodyHash:
    raiseRuntime("provider dev-env body hash mismatch")
  if devEnv.projectRoot != request.arguments:
    raiseRuntime("provider dev-env project root mismatch")
  if devEnv.lockSliceId != request.lockSliceId:
    raiseRuntime("provider dev-env lock slice mismatch")

  let descriptors = manifestById(manifest)
  if not descriptors.hasKey(request.entryPointId):
    raiseRuntime("provider dev-env entry point is absent from manifest")
  let descriptor = descriptors[request.entryPointId]
  if descriptor.kind != gpkDevEnvIntrospection:
    raiseRuntime("provider dev-env entry point has the wrong kind")
  if descriptor.bodyHash != request.entryPointBodyHash:
    raiseRuntime("provider dev-env body hash does not match manifest")

proc invokeProviderDevEnvIntrospection*(config: ProviderExecutionConfig;
                                        providerArtifactId, projectRoot: string;
                                        entryPointId = "";
                                        activity = "";
                                        lockSliceId = ""): DevEnvResult =
  let manifest = readProviderManifest(config, providerArtifactId)
  let selectedEntryPoint =
    if entryPointId.len > 0:
      entryPointId
    else:
      var found = ""
      for descriptor in manifest.entryPoints:
        if descriptor.kind == gpkDevEnvIntrospection:
          found = descriptor.id
          break
      if found.len == 0:
        raiseRuntime("provider manifest does not expose dev-env introspection")
      found
  let descriptors = manifestById(manifest)
  if not descriptors.hasKey(selectedEntryPoint):
    raiseRuntime("dev-env entry point is missing from provider manifest")
  let descriptor = descriptors[selectedEntryPoint]
  if descriptor.kind != gpkDevEnvIntrospection:
    raiseRuntime("entry point is not dev-env introspection: " &
      selectedEntryPoint)
  let selectedActivity =
    if activity.len > 0: activity else: "default"
  let request = ProviderGraphRequest(
    kind: prkDevEnvIntrospection,
    providerArtifactId: providerArtifactId,
    entryPointId: selectedEntryPoint,
    entryPointBodyHash: descriptor.bodyHash,
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    lockSliceId: lockSliceId,
    activity: selectedActivity)
  var response = runProviderProtocol(config, request)
  if response.kind != pskDevEnvResult:
    raiseRuntime("provider dev-env request did not return a dev-env result")
  validateManifest(response.manifest, providerArtifactId)
  validateDevEnvResult(response.devEnv, request, response.manifest)
  response.resolveRelativeResponsePaths(
    if config.workingDir.len > 0: config.workingDir else: getCurrentDir())
  let expectedActivities = splitActivities(selectedActivity)
  if response.devEnv.selectedActivities != expectedActivities:
    raiseRuntime("provider dev-env activity selection mismatch")
  response.devEnv

proc fileContentDigest*(path: string): string =
  if not fileExists(extendedPath(path)):
    return "missing"
  digestHex(toBytes(readFile(extendedPath(path))))

proc directoryMemberNames*(path: string): seq[string] =
  ## The sorted names of the entries of the directory ``path`` names, or none
  ## when it is not a directory. A pattern-scoped name
  ## (``repro_local_store/pattern_scoped_enumeration``: a directory, a NUL
  ## and a glob component, as the io monitor reports a scan such as Nim's
  ## search for ``<dir>/*.nimble``) lists only the entries that match the
  ## component, so an evaluation input recorded from such a scan changes
  ## only when a matching entry appears or goes.
  let (dir, pattern) = splitPatternScopedEnumeration(path)
  if not dirExists(extendedPath(dir)):
    return @[]
  for kind, child in walkDir(extendedPath(dir)):
    if kind in {pcFile, pcDir, pcLinkToFile, pcLinkToDir}:
      let name = splitPath(child).tail
      if pattern.len == 0 or globComponentMatches(pattern, name):
        result.add(name)
  result.sort()

proc directoryMembersDigest(members: openArray[string]): string =
  var payload: seq[byte] = @[]
  for member in members:
    payload.writeString(member)
  digestHex(payload)

proc fileReadInput*(path: string): GraphEvaluationInput =
  GraphEvaluationInput(kind: gevFileRead, identity: path,
    digest: fileContentDigest(path))

proc recordedFileReadInput*(path, digest: string): GraphEvaluationInput =
  ## A file-read evaluation input whose digest the caller took when it
  ## decided what the graph was derived from (``fileContentDigest`` of the
  ## content the graph reflects), rather than now. A producer that checks a
  ## tool's reads for stability and then registers them must report the
  ## digests it checked: re-reading the file at registration would record an
  ## edit made in between against a graph derived from the old content, and
  ## that graph would then be reused after the edit.
  GraphEvaluationInput(kind: gevFileRead, identity: path, digest: digest)

const UnobservedEvaluationDigest* = "unobserved"
  ## The digest of an evaluation input whose content the producer could NOT
  ## observe. ``fileContentDigest`` returns a hex digest or ``missing`` and
  ## never this value, so the input reads as changed on every refresh and the
  ## owning fragment is produced again every time.

proc unobservedEvaluationInput*(identity: string): GraphEvaluationInput =
  ## An evaluation input for a graph derived from reads that could not be
  ## observed completely — Failure-Semantics.md §"Monitoring Failures": when
  ## the scope of a loss is unknown, nothing derived from it is reused. The
  ## fragment that carries it is never served from the snapshot; every
  ## refresh re-invokes its entry point (and early cutoff still applies when
  ## the rerun reproduces it unchanged). ``identity`` names what was not
  ## observed, for the reader of the snapshot.
  GraphEvaluationInput(kind: gevFileRead, identity: identity,
    digest: UnobservedEvaluationDigest)

const EnvironmentHostFactPrefix* = "env:"
  ## Identity prefix of a host fact that is an environment variable:
  ## ``env:<NAME>`` (Project-Provider-Graph-Protocol.md §"Evaluation
  ## Inputs").

proc environmentValueDigest(name: string): string =
  ## A digest of ``name``'s value in this process's environment, or
  ## ``unset``. The value itself is not stored: an environment variable may
  ## hold a secret, and a snapshot is not a place for one.
  if existsEnv(name):
    digestHex(toBytes("set:" & getEnv(name)))
  else:
    "unset"

proc environmentInput*(name: string): GraphEvaluationInput =
  ## An evaluation input for a graph shaped by the environment variable
  ## ``name``, as a tool the provider ran at evaluation time read it. The
  ## engine spawns the provider with its own environment, so it re-checks
  ## the input against its own value of ``name`` (``hostFactDigest``).
  GraphEvaluationInput(kind: gevHostFact,
    identity: EnvironmentHostFactPrefix & name,
    digest: environmentValueDigest(name))

proc hostFactDigest*(identity: string): string =
  ## The current digest of the host fact ``identity``, to compare with the
  ## one a fragment recorded. An identity this build cannot evaluate yields
  ## ``""``, which no recorded digest equals, so the fragment that recorded
  ## it is produced again rather than reused on a fact nobody checked.
  if identity.startsWith(EnvironmentHostFactPrefix) and
      identity.len > EnvironmentHostFactPrefix.len:
    environmentValueDigest(identity[EnvironmentHostFactPrefix.len .. ^1])
  else:
    ""

proc providerSourceInput*(providerArtifactId, binaryDigest: string):
    GraphEvaluationInput =
  ## The record of WHICH PROVIDER produced a fragment: its artifact id, and
  ## the content digest of the binary that ran (the digest
  ## ``fileReadInput`` computes for that binary).
  ##
  ## ``executePlan`` adds one to every fragment it stores -- the root and
  ## every child -- and ``providerSnapshotBinaryFresh`` refuses a snapshot
  ## in which any fragment's record names a different provider or lacks
  ## one. That is what makes "a stored fragment is reused only when it was
  ## produced by the current provider source" a property of the stored data
  ## rather than of the order the refresh happens to check things in.
  ##
  ## An unchanged entry point id and body hash NEVER justify keeping a
  ## fragment across a provider change by themselves. The body hashes the
  ## DSL ships are not closure-complete: the project root's is the constant
  ## ``<package>.build.v1`` (``runtime_provider.nim``), and a ``foreach``
  ## body's is a digest of its untyped syntax (``liftForeachStatements`` in
  ## ``macros_b.nim``), which covers no callee, no package-scope state, no
  ## global and not the compiler. A change to any of those leaves the hash
  ## as it was and the graph it produces different.
  GraphEvaluationInput(kind: gevProviderSource, identity: providerArtifactId,
    digest: binaryDigest)

proc providerSnapshotBinaryFresh*(snapshot: ProviderGraphSnapshot;
                                  binaryPath: string): bool =
  ## Whether ``snapshot`` was produced, fragment by fragment, by the provider
  ## at ``binaryPath``: the ONE freshness predicate over the provider that
  ## both the refresh (``refreshProviderGraph``) and the CLI's cached
  ## snapshot reads apply before serving a stored fragment.
  ##
  ## Two conditions, both required:
  ##
  ## * The binary binding: the snapshot holds a ``gevFileRead`` input on
  ##   ``binaryPath`` (the root fragment carries it), and every such input
  ##   matches the binary's current content.
  ## * The provider source: EVERY fragment records a ``gevProviderSource``
  ##   (``providerSourceInput``), and every such record names the
  ##   snapshot's ``providerArtifactId`` and the binary's current digest. A
  ##   child fragment carries no other trace of the provider that produced
  ##   it, so without this a child kept from an earlier provider would be
  ##   served as current whenever the root's binding happened to be fresh.
  ##
  ## A snapshot failing either is not reused at all: the refresh then runs
  ## the root and every child again. That includes a LEGACY snapshot,
  ## written before the record existed, which is therefore evaluated once.
  let digest = fileContentDigest(binaryPath)
  if digest == "missing" or snapshot.fragments.len == 0:
    return false
  var bound = false
  for fragment in snapshot.fragments:
    var sourced = false
    for input in fragment.evaluationInputs:
      case input.kind
      of gevFileRead:
        if input.identity == binaryPath:
          if input.digest != digest:
            return false
          bound = true
      of gevProviderSource:
        if input.identity != snapshot.providerArtifactId or
            input.digest != digest:
          return false
        sourced = true
      else:
        discard
    if not sourced:
      return false
  bound

proc requireUnchangedProviderBinary(input: GraphEvaluationInput) =
  if fileContentDigest(input.identity) != input.digest:
    raiseRuntime("provider binary changed during graph refresh")

proc directoryEnumerationInput*(path, memberEntryPointId,
                                memberEntryPointBodyHash: string;
                                memberArgumentRoot = "";
                                memberNamespace = ""): GraphEvaluationInput =
  let members = directoryMemberNames(path)
  GraphEvaluationInput(
    kind: gevDirectoryEnumeration,
    identity: path,
    digest: directoryMembersDigest(members),
    directoryMembers: members,
    memberEntryPointId: memberEntryPointId,
    memberEntryPointBodyHash: memberEntryPointBodyHash,
    memberArgumentRoot: if memberArgumentRoot.len > 0: memberArgumentRoot else: path,
    memberNamespace: memberNamespace)

proc recordedDirectoryEnumerationInput*(path: string;
                                        members: seq[string]):
    GraphEvaluationInput =
  ## A directory-enumeration evaluation input with the member names the
  ## caller listed when it decided what the graph was derived from, for the
  ## reason ``recordedFileReadInput`` gives. ``path`` may be a pattern-scoped
  ## name (``directoryMemberNames``).
  var sorted = members
  sorted.sort()
  GraphEvaluationInput(
    kind: gevDirectoryEnumeration,
    identity: path,
    digest: directoryMembersDigest(sorted),
    directoryMembers: sorted,
    memberArgumentRoot: path)

proc emptyProviderGraphSnapshot*(providerArtifactId: string;
                                 manifest: ProviderManifest):
    ProviderGraphSnapshot =
  ProviderGraphSnapshot(providerArtifactId: providerArtifactId,
    manifest: manifest)

proc invocationKeyFor(config: RefreshConfig; entryPointId, arguments,
                      namespace: string): string =
  ## The key ``config``'s refresh stores the invocation of ``entryPointId``
  ## on ``arguments`` in ``namespace`` under.
  graphInvocationKey(config.projectId, entryPointId, arguments,
    config.lockSliceId, config.activity, namespace)

proc storedFragmentFrom(fragment: GraphFragment;
                        config: RefreshConfig): StoredGraphFragment =
  ## The stored form of a fragment ``config``'s refresh produced: keyed by
  ## the invocation, carrying the producing provider artifact and the entry
  ## point body hash as validity attributes beside it.
  let argDigest = argumentDigest(fragment.arguments)
  StoredGraphFragment(
    invocationKey: invocationKeyFor(config, fragment.entryPointId,
      fragment.arguments, fragment.namespace),
    providerArtifactId: config.providerArtifactId,
    entryPointId: fragment.entryPointId,
    entryPointBodyHash: fragment.entryPointBodyHash,
    arguments: fragment.arguments,
    argumentDigest: argDigest,
    lockSliceId: config.lockSliceId,
    activity: config.activity,
    namespace: fragment.namespace,
    fragmentDigest: fragment.fragmentDigest,
    nodes: fragment.nodes,
    edges: fragment.edges,
    effectClaims: fragment.effectClaims,
    childEntryPoints: fragment.childEntryPoints,
    evaluationInputs: fragment.evaluationInputs)

proc reusableIndex(snapshot: ProviderGraphSnapshot;
                   fragment: StoredGraphFragment): int =
  ## The stored fragment ``fragment`` replaces: the one under the same
  ## invocation key, or -1.
  ##
  ## Matched by key and nothing else. The key no longer moves when the
  ## provider is recompiled, so there is no attribute-matching fallback to
  ## find "the same" fragment under another key -- and there must not be:
  ## a fragment of another lock slice or activity is another invocation,
  ## which is pruned, not replaced.
  for i, existing in snapshot.fragments:
    if existing.invocationKey == fragment.invocationKey:
      return i
  -1

proc recordReplacement(report: var ProviderRefreshReport;
                       oldFragment, newFragment: StoredGraphFragment) =
  if oldFragment.fragmentDigest == newFragment.fragmentDigest:
    report.earlyCutoffs.add(newFragment.invocationKey)

  var newEffects = initHashSet[string]()
  for claim in newFragment.effectClaims:
    newEffects.incl(effectKey(claim))
  for claim in oldFragment.effectClaims:
    if not newEffects.contains(effectKey(claim)):
      report.staleEffects.add(StaleOwnedEffect(
        invocationKey: oldFragment.invocationKey,
        claim: claim))

  var newEdges = initHashSet[string]()
  for edge in newFragment.edges:
    newEdges.incl(edgeKey(edge))
  for edge in oldFragment.edges:
    if not newEdges.contains(edgeKey(edge)):
      report.staleEdges.add(StaleOwnedEdge(
        invocationKey: oldFragment.invocationKey,
        edge: edge))

proc applyStoredFragment(snapshot: var ProviderGraphSnapshot;
                         report: var ProviderRefreshReport;
                         fragment: StoredGraphFragment) =
  let index = reusableIndex(snapshot, fragment)
  if index >= 0:
    recordReplacement(report, snapshot.fragments[index], fragment)
    snapshot.fragments[index] = fragment
  else:
    snapshot.fragments.add(fragment)

proc findFragmentByEntryArgs(snapshot: ProviderGraphSnapshot; entryPointId,
                             arguments, namespace: string): int =
  for i, fragment in snapshot.fragments:
    if fragment.entryPointId == entryPointId and
        fragment.arguments == arguments and
        fragment.namespace == namespace:
      return i
  -1

proc pruneFragmentAt(snapshot: var ProviderGraphSnapshot;
                     report: var ProviderRefreshReport; index: int) =
  if index < 0 or index >= snapshot.fragments.len:
    return
  let removed = snapshot.fragments[index]
  snapshot.fragments.delete(index)
  report.prunedInvocationKeys.add(removed.invocationKey)
  for claim in removed.effectClaims:
    report.staleEffects.add(StaleOwnedEffect(
      invocationKey: removed.invocationKey,
      claim: claim))
  for edge in removed.edges:
    report.staleEdges.add(StaleOwnedEdge(
      invocationKey: removed.invocationKey,
      edge: edge))
  for child in removed.childEntryPoints:
    let childIndex = findFragmentByEntryArgs(snapshot, child.entryPointId,
      child.arguments, child.namespace)
    if childIndex >= 0:
      pruneFragmentAt(snapshot, report, childIndex)

proc ensureNoDuplicateEffects(snapshot: ProviderGraphSnapshot) =
  var owners = initTable[string, string]()
  for fragment in snapshot.fragments:
    for claim in fragment.effectClaims:
      let key = $claim.kind & "|" & claim.identity
      if owners.hasKey(key) and owners[key] != fragment.invocationKey:
        raiseRuntime("duplicate live owned effect claim: " & key)
      owners[key] = fragment.invocationKey

proc currentDescriptor(manifest: ProviderManifest; entryPointId: string):
    tuple[found: bool; descriptor: GraphEntryPointDescriptor] =
  let descriptors = manifestById(manifest)
  if descriptors.hasKey(entryPointId):
    (found: true, descriptor: descriptors[entryPointId])
  else:
    (found: false, descriptor: GraphEntryPointDescriptor())

proc execConfig(config: RefreshConfig): ProviderExecutionConfig =
  result = ProviderExecutionConfig(
    binaryPath: config.providerBinaryPath,
    extraArgs: config.providerExtraArgs,
    workingDir: if config.providerWorkingDir.len > 0:
      config.providerWorkingDir else: getCurrentDir(),
    tempRoot: config.storeRoot / "tmp")

proc providerBinaryInputPath(provider: ProviderExecutionConfig): string =
  let workingDir = absolutePath(provider.workingDir)
  if provider.binaryPath.isAbsolute() or provider.binaryPath.splitPath().head.len > 0:
    return absolutePath(provider.binaryPath, workingDir)

  # Match process lookup from the child's directory without changing the
  # parent's cwd or the command spelling supplied to the provider.
  var searchDirs: seq[string] = @[]
  when defined(windows):
    searchDirs.add(workingDir)
  var searchPath = getEnv("PATH")
  when defined(posix):
    if not existsEnv("PATH"):
      let size = posix.confstr(posix.CS_PATH, nil, 0)
      if size <= 0:
        return ""
      searchPath = newString(size)
      let written = posix.confstr(posix.CS_PATH, searchPath.cstring, size)
      if written <= 0 or written > size:
        return ""
      searchPath.setLen(written - 1)
  for entry in searchPath.split(PathSep):
    when defined(windows):
      if entry.len == 0:
        continue
      let directory = if entry.len >= 2 and entry[0] == '"' and entry[^1] == '"':
        entry[1 ..< entry.len - 1] else: entry
    else:
      let directory = if entry.len == 0: workingDir else: entry
    searchDirs.add(absolutePath(directory, workingDir))
  for directory in searchDirs:
    for extension in ExeExts:
      let candidate = addFileExt(directory / provider.binaryPath, extension)
      if fileExists(extendedPath(candidate)):
        when defined(posix):
          if posix.access(candidate.cstring, posix.X_OK) != 0:
            continue
        return candidate

proc enqueue(plans: var seq[InvocationPlan]; planKeys: var HashSet[string];
             plan: InvocationPlan) =
  let key = plan.entryPointId & "|" & plan.arguments & "|" & plan.namespace
  if not planKeys.contains(key):
    plans.add(plan)
    planKeys.incl(key)

proc memberArgument(input: GraphEvaluationInput; member: string): string =
  let root =
    if input.memberArgumentRoot.len > 0: input.memberArgumentRoot
    else: input.identity
  root / member

proc childSpecForMember(input: GraphEvaluationInput; member: string;
                        descriptor: GraphEntryPointDescriptor;
                        ownerNamespace: string): GraphEntryPointInvocationSpec =
  let ns =
    if input.memberNamespace.len > 0: input.memberNamespace
    else: ownerNamespace
  GraphEntryPointInvocationSpec(
    entryPointId: input.memberEntryPointId,
    entryPointBodyHash: descriptor.bodyHash,
    arguments: memberArgument(input, member),
    namespace: ns,
    stableName: descriptor.stableName & ":" & member)

proc addChildSpec(owner: var StoredGraphFragment;
                  child: GraphEntryPointInvocationSpec) =
  for existing in owner.childEntryPoints:
    if existing.entryPointId == child.entryPointId and
        existing.arguments == child.arguments and
        existing.namespace == child.namespace:
      return
  owner.childEntryPoints.add(child)

proc removeChildSpec(owner: var StoredGraphFragment; entryPointId, arguments,
                     namespace: string) =
  var kept: seq[GraphEntryPointInvocationSpec] = @[]
  for child in owner.childEntryPoints:
    if child.entryPointId == entryPointId and child.arguments == arguments and
        child.namespace == namespace:
      discard
    else:
      kept.add(child)
  owner.childEntryPoints = kept

proc refreshStoredBindings(snapshot: var ProviderGraphSnapshot;
                           manifest: ProviderManifest) =
  let descriptors = manifestById(manifest)
  for i in 0 ..< snapshot.fragments.len:
    for j in 0 ..< snapshot.fragments[i].evaluationInputs.len:
      let entryPointId = snapshot.fragments[i].evaluationInputs[j].memberEntryPointId
      if entryPointId.len > 0 and descriptors.hasKey(entryPointId):
        snapshot.fragments[i].evaluationInputs[j].memberEntryPointBodyHash =
          descriptors[entryPointId].bodyHash
    for j in 0 ..< snapshot.fragments[i].childEntryPoints.len:
      let entryPointId = snapshot.fragments[i].childEntryPoints[j].entryPointId
      if descriptors.hasKey(entryPointId):
        snapshot.fragments[i].childEntryPoints[j].entryPointBodyHash =
          descriptors[entryPointId].bodyHash

proc updateDirectoryInput(owner: var StoredGraphFragment; inputIndex: int;
                          members: seq[string]; bodyHash: string) =
  owner.evaluationInputs[inputIndex].directoryMembers = members
  owner.evaluationInputs[inputIndex].digest = directoryMembersDigest(members)
  owner.evaluationInputs[inputIndex].memberEntryPointBodyHash = bodyHash

proc handleDirectoryChanges(config: RefreshConfig; manifest: ProviderManifest;
                            snapshot: var ProviderGraphSnapshot;
                            report: var ProviderRefreshReport;
                            plans: var seq[InvocationPlan];
                            planKeys: var HashSet[string];
                            rootNeedsRerun: var bool) =
  let descriptors = manifestById(manifest)
  var ownerIndex = 0
  while ownerIndex < snapshot.fragments.len:
    var inputIndex = 0
    while inputIndex < snapshot.fragments[ownerIndex].evaluationInputs.len:
      let input = snapshot.fragments[ownerIndex].evaluationInputs[inputIndex]
      if input.kind != gevDirectoryEnumeration:
        inc inputIndex
        continue
      let currentMembers = directoryMemberNames(input.identity)
      var added: seq[string] = @[]
      var removed: seq[string] = @[]
      for member in currentMembers:
        if input.directoryMembers.find(member) < 0:
          added.add(member)
      for member in input.directoryMembers:
        if currentMembers.find(member) < 0:
          removed.add(member)
      if added.len == 0 and removed.len == 0:
        inc inputIndex
        continue
      if input.memberEntryPointId.len == 0 or
          not descriptors.hasKey(input.memberEntryPointId):
        rootNeedsRerun = true
        inc inputIndex
        continue

      let descriptor = descriptors[input.memberEntryPointId]
      for member in removed:
        let spec = childSpecForMember(input, member, descriptor,
          snapshot.fragments[ownerIndex].namespace)
        let fragmentIndex = findFragmentByEntryArgs(snapshot, spec.entryPointId,
          spec.arguments, spec.namespace)
        if fragmentIndex >= 0:
          pruneFragmentAt(snapshot, report, fragmentIndex)
          if ownerIndex >= snapshot.fragments.len:
            break
        if ownerIndex < snapshot.fragments.len:
          removeChildSpec(snapshot.fragments[ownerIndex], spec.entryPointId,
            spec.arguments, spec.namespace)

      if ownerIndex >= snapshot.fragments.len:
        break

      for member in added:
        let spec = childSpecForMember(input, member, descriptor,
          snapshot.fragments[ownerIndex].namespace)
        addChildSpec(snapshot.fragments[ownerIndex], spec)
        enqueue(plans, planKeys, InvocationPlan(
          entryPointId: spec.entryPointId,
          entryPointBodyHash: spec.entryPointBodyHash,
          arguments: spec.arguments,
          namespace: spec.namespace,
          reason: girDirectoryMembershipChanged))

      updateDirectoryInput(snapshot.fragments[ownerIndex], inputIndex,
        currentMembers, descriptor.bodyHash)
      inc inputIndex
    inc ownerIndex

proc executePlan(config: RefreshConfig; provider: ProviderExecutionConfig;
                 binaryInput: GraphEvaluationInput;
                 manifest: ProviderManifest; snapshot: var ProviderGraphSnapshot;
                 report: var ProviderRefreshReport; plan: InvocationPlan):
    StoredGraphFragment =
  requireInvocationProjectRoot(plan.arguments, plan.entryPointId,
    config.providerArtifactId)
  let request = ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: config.providerArtifactId,
    entryPointId: plan.entryPointId,
    entryPointBodyHash: plan.entryPointBodyHash,
    reason: plan.reason,
    arguments: plan.arguments,
    namespace: plan.namespace,
    lockSliceId: config.lockSliceId,
    activity: config.activity)
  let response = invokeProviderEntryPoint(provider, request)
  if response.manifest.entryPoints != manifest.entryPoints:
    raiseRuntime("provider manifest changed during refresh")
  report.invoked.add(ProviderInvocationRecord(
    entryPointId: plan.entryPointId,
    arguments: plan.arguments,
    reason: plan.reason))
  var fragment = response.fragment
  # Which provider produced this fragment is the ENGINE's record, not the
  # provider's claim: drop any provider-source input the response carried,
  # so every stored fragment holds exactly the one written below.
  var inputs: seq[GraphEvaluationInput] = @[]
  for input in fragment.evaluationInputs:
    if input.kind != gevProviderSource:
      inputs.add(input)
  # Every fragment, root and child, records the provider source that
  # produced it; ``providerSnapshotBinaryFresh`` refuses to reuse any
  # fragment whose record is not the current provider's. An unchanged entry
  # point id / body hash is never enough on its own (see
  # ``providerSourceInput`` for why).
  inputs.add(providerSourceInput(config.providerArtifactId, binaryInput.digest))
  if plan.entryPointId == config.rootEntryPointId:
    # A monitored recompile may change the binary without changing the
    # protocol's textual source identity. Bind its graph to the actual code.
    inputs.add(binaryInput)
  fragment.evaluationInputs = inputs
  # The fragment digest is over the fragment's CONTENT (nodes, edges,
  # effects, children: ``encodeFragmentForDigest``), not its evaluation
  # inputs, so the records added above leave it unchanged. That is
  # deliberate. Reuse is governed by the recorded provider source; the
  # digest is what ``recordReplacement`` compares for early cutoff, and a
  # new provider that reproduces a child's content exactly must still cut
  # off downstream work. Recomputed anyway so the stored digest is, by
  # construction, the one ``computeGraphFragmentDigest`` gives for the
  # stored fragment.
  fragment.fragmentDigest = computeGraphFragmentDigest(fragment)
  result = storedFragmentFrom(fragment, config)
  applyStoredFragment(snapshot, report, result)

proc runRootAndChildren(config: RefreshConfig; provider: ProviderExecutionConfig;
                        binaryInput: GraphEvaluationInput;
                        manifest: ProviderManifest;
                        snapshot: var ProviderGraphSnapshot;
                        report: var ProviderRefreshReport;
                        reason: GraphInvocationReason) =
  let root = currentDescriptor(manifest, config.rootEntryPointId)
  if not root.found:
    # The root entry point is named from the project INTERFACE; the provider
    # declares its own. They disagree when the two compiles saw different
    # declarations - most plausibly a recipe `config.nims` / `nim.cfg`, which
    # the provider compile reads and the interface (computed as an importer
    # sees the package) does not (Hermetic-Builds-And-Path-Independence.md
    # §"Engine-internal recipe compiles"). Name both sides.
    var offered: seq[string] = @[]
    for descriptor in manifest.entryPoints:
      if descriptor.kind == gpkProjectRoot:
        offered.add(descriptor.id)
    raiseRuntime("root entry point is missing from provider manifest: the " &
      "project interface names '" & config.rootEntryPointId &
      "', the provider declares " &
      (if offered.len > 0: "'" & offered.join("', '") & "'" else: "none") &
      ". The interface and the provider were compiled from different " &
      "declarations; a recipe configuration file (config.nims, nim.cfg) " &
      "applies to the provider compile only, and must not change what the " &
      "recipe declares")
  let rootStored = executePlan(config, provider, binaryInput, manifest, snapshot, report,
    InvocationPlan(
      entryPointId: root.descriptor.id,
      entryPointBodyHash: root.descriptor.bodyHash,
      arguments: config.rootArguments,
      namespace: config.namespace,
      reason: reason))
  for child in rootStored.childEntryPoints:
    discard executePlan(config, provider, binaryInput, manifest, snapshot, report, InvocationPlan(
      entryPointId: child.entryPointId,
      entryPointBodyHash: child.entryPointBodyHash,
      arguments: child.arguments,
      namespace: child.namespace,
      reason: girNoPriorFragment))

proc detectEvaluationInputChanges(manifest: ProviderManifest;
                                  snapshot: ProviderGraphSnapshot;
                                  plans: var seq[InvocationPlan];
                                  planKeys: var HashSet[string]) =
  for fragment in snapshot.fragments:
    var changed = false
    for input in fragment.evaluationInputs:
      case input.kind
      of gevFileRead:
        if fileContentDigest(input.identity) != input.digest:
          changed = true
      of gevDirectoryEnumeration:
        # Membership changes are handled by ``handleDirectoryChanges``.
        discard
      of gevHostFact:
        if hostFactDigest(input.identity) != input.digest:
          changed = true
      of gevProviderSource:
        # Not re-checked per fragment: ``refreshProviderGraph`` reaches this
        # pass only for a snapshot ``providerSnapshotBinaryFresh`` accepted,
        # which already requires every fragment's record to be the current
        # provider's. A snapshot that fails it is not reused at all.
        discard
      else:
        discard
    if changed:
      let descriptor = currentDescriptor(manifest, fragment.entryPointId)
      if descriptor.found:
        enqueue(plans, planKeys, InvocationPlan(
          entryPointId: fragment.entryPointId,
          entryPointBodyHash: descriptor.descriptor.bodyHash,
          arguments: fragment.arguments,
          namespace: fragment.namespace,
          reason: girEvaluationInputChanged))

proc requireRefreshProjectId(config: RefreshConfig) =
  ## The project is the first component of every invocation key a refresh
  ## stores (``graphInvocationKey``). An empty one would key the fragments
  ## of every project that left it out alike, so two projects sharing a
  ## store would replace each other's fragments as if they were one
  ## invocation. Refuse it before anything is spawned or read, naming the
  ## entry point the refresh was for.
  if config.projectId.len == 0:
    raiseRuntime("provider graph refresh has no project id: entry point '" &
      config.rootEntryPointId & "' of provider artifact '" &
      config.providerArtifactId & "'; the caller must supply the package " &
      "name of the project it refreshes")

proc providerSnapshotKeyedFor*(snapshot: ProviderGraphSnapshot;
                               config: RefreshConfig): bool =
  ## Whether every stored fragment is an invocation THIS refresh would make:
  ## its stored key is the one ``config`` gives its entry point, arguments
  ## and namespace. False when the project, the lock slice or the activity
  ## changed -- each a different invocation -- and for a snapshot keyed in
  ## an earlier shape of the key, whose fragments are then produced again
  ## once.
  ##
  ## Each fragment is keyed from its OWN stored arguments, so that alone
  ## cannot see a refresh for another root. The snapshot must also hold the
  ## root invocation this refresh requests -- the root entry point on
  ## ``config.rootArguments`` in ``config.namespace``. A different root
  ## argument gives the root fragment a different key (its argument
  ## digest), so a snapshot produced for another root is not reused without
  ## invoking the root (Project-Provider-Graph-Protocol.md §"Full Versus
  ## Fragment Invocation"), even when the provider artifact does not depend
  ## on the root and so does not force the invocation itself.
  ##
  ## Exported because ``refreshProviderGraph`` is not the only reuse site: a
  ## caller that serves a stored snapshot WITHOUT refreshing it (the CLI's
  ## warm snapshot shortcut) must apply the same rule, or it would serve the
  ## graph this refresh refuses.
  let rootKey = invocationKeyFor(config, config.rootEntryPointId,
    config.rootArguments, config.namespace)
  var holdsRequestedRoot = false
  for fragment in snapshot.fragments:
    if fragment.invocationKey != invocationKeyFor(config,
        fragment.entryPointId, fragment.arguments, fragment.namespace):
      return false
    if fragment.invocationKey == rootKey:
      holdsRequestedRoot = true
  holdsRequestedRoot

proc refreshProviderGraph*(config: RefreshConfig): ProviderRefreshReport =
  ## Bring the persisted provider-graph snapshot up to date and return it.
  ##
  ## The reuse rule: a stored fragment is reused only when it was produced
  ## by the CURRENT provider source -- the snapshot's artifact id is this
  ## config's, and ``providerSnapshotBinaryFresh`` finds every fragment's
  ## recorded ``gevProviderSource`` to be this binary. Then only the
  ## fragments whose own evaluation inputs (files read, directory
  ## membership) changed are re-invoked. Otherwise the root and every child
  ## are run again and the old snapshot is consulted only to report what was
  ## replaced, cut off or pruned.
  ##
  ## There is deliberately no third arm that keeps fragments across a
  ## provider change because their entry point id and body hash are
  ## unchanged. The body hashes the DSL ships are not closure-complete (see
  ## ``providerSourceInput``), so such an arm would serve a stale graph
  ## after, for example, a change to a helper proc or a package-scope flag.
  ##
  ## Re-running is not re-keying. Every fragment is stored under its
  ## invocation key (``graphInvocationKey``), which does not name the
  ## provider, so a fragment the new provider re-produces replaces the
  ## stored one under the same key: an equal digest is reported as an early
  ## cutoff, and only what it no longer owns is reported stale. A stored
  ## fragment whose key this refresh does not reproduce -- another lock
  ## slice, activity, project or root, or a member that is gone -- is
  ## pruned, and its effects become cleanup candidates that a surviving
  ## claim on the same effect still protects (``planOutputCleanup``).
  # Before anything is spawned or read: a refresh with no project root
  # cannot produce a usable graph, and every plan below inherits this
  # value. Nor can one with no project, which every key below names.
  requireInvocationProjectRoot(config.rootArguments, config.rootEntryPointId,
    config.providerArtifactId)
  requireRefreshProjectId(config)
  result.persistedSnapshotPath = providerSnapshotPath(config.storeRoot)
  let provider = execConfig(config)
  let binaryInput = fileReadInput(providerBinaryInputPath(provider))
  if binaryInput.digest == "missing":
    raiseRuntime("provider binary is missing: " & config.providerBinaryPath)
  var snapshot = loadProviderGraphSnapshot(config.storeRoot)

  let providerFresh = snapshot.fragments.len > 0 and
    snapshot.providerArtifactId == config.providerArtifactId and
    providerSnapshotBinaryFresh(snapshot, binaryInput.identity)
  if providerFresh and providerSnapshotKeyedFor(snapshot, config):
    let manifest = snapshot.manifest
    validateManifest(manifest, config.providerArtifactId)
    refreshStoredBindings(snapshot, manifest)

    var plans: seq[InvocationPlan] = @[]
    var planKeys = initHashSet[string]()
    var rootNeedsRerun = false

    handleDirectoryChanges(config, manifest, snapshot, result, plans, planKeys,
      rootNeedsRerun)
    detectEvaluationInputChanges(manifest, snapshot, plans, planKeys)

    if rootNeedsRerun:
      runRootAndChildren(config, provider, binaryInput, manifest, snapshot, result,
        girDirectoryMembershipChanged)
    else:
      for plan in plans:
        discard executePlan(config, provider, binaryInput, manifest, snapshot, result, plan)

    ensureNoDuplicateEffects(snapshot)
    requireUnchangedProviderBinary(binaryInput)
    if plans.len > 0 or rootNeedsRerun or result.prunedInvocationKeys.len > 0 or
        result.staleEffects.len > 0 or result.staleEdges.len > 0:
      saveProviderGraphSnapshot(config.storeRoot, snapshot)
    result.snapshot = snapshot
    return

  let manifest = readProviderManifest(provider, config.providerArtifactId)
  validateManifest(manifest, config.providerArtifactId)

  if snapshot.fragments.len == 0:
    snapshot = emptyProviderGraphSnapshot(config.providerArtifactId, manifest)
    runRootAndChildren(config, provider, binaryInput, manifest, snapshot, result,
      girColdStart)
    ensureNoDuplicateEffects(snapshot)
    requireUnchangedProviderBinary(binaryInput)
    saveProviderGraphSnapshot(config.storeRoot, snapshot)
    result.snapshot = snapshot
    return

  # The stored graph cannot be reused: either another provider produced it
  # (the validity attributes), or the provider is current and the
  # invocations are not (the keys, including the requested root's). Run
  # the root and every child again; the previous snapshot only decides what
  # is reported replaced, cut off or pruned.
  let previous = snapshot
  snapshot = emptyProviderGraphSnapshot(config.providerArtifactId, manifest)
  runRootAndChildren(config, provider, binaryInput, manifest, snapshot, result,
    if providerFresh: girLockOrConfigChanged else: girProviderArtifactChanged)
  ensureNoDuplicateEffects(snapshot)
  requireUnchangedProviderBinary(binaryInput)
  for oldFragment in previous.fragments:
    let index = reusableIndex(snapshot, oldFragment)
    if index >= 0:
      recordReplacement(result, oldFragment, snapshot.fragments[index])
    else:
      result.prunedInvocationKeys.add(oldFragment.invocationKey)
      for claim in oldFragment.effectClaims:
        result.staleEffects.add(StaleOwnedEffect(
          invocationKey: oldFragment.invocationKey, claim: claim))
      for edge in oldFragment.edges:
        result.staleEdges.add(StaleOwnedEdge(
          invocationKey: oldFragment.invocationKey, edge: edge))
  saveProviderGraphSnapshot(config.storeRoot, snapshot)
  result.snapshot = snapshot
