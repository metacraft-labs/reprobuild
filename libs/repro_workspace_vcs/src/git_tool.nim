## Workspace VCS — typed identity for ``git`` (Phase 1 / M1).
##
## This module establishes a stable, per-host ``GitToolIdentity`` that
## participates in action fingerprints whenever a VCS action is in play.
## A workspace built against git 2.40 and the same workspace built against
## git 2.45 must not be confused by the action cache when their behaviour
## actually depends on the git version, so the identity captures the
## binary path, the version string reported by ``git --version``, and the
## declared host platform (OS + CPU). All three feed a single content
## digest comparable across processes.
##
## The module reuses ``repro_tool_profiles`` for tool surfacing so we do
## NOT introduce a parallel mechanism. For now only the
## ``tpmPathOnly`` provisioning mode is wired end-to-end: future
## milestones will extend the same identity helper to ``tpmNix``,
## ``tpmTarball`` and ``tpmScoop`` once a first-class git acquisition
## plan is declared. Until then those modes raise ``EGitToolUnresolved``
## with a clear message naming the active ``--tool-provisioning=`` mode.

import std/[os, osproc, strtabs, strutils]

import repro_core/codec
import repro_hash
import repro_hash/text as hashText
import repro_interface_artifacts
import repro_platform
import repro_tool_profiles

export ToolProvisioningMode

type
  GitToolIdentity* = object
    ## Per-host identity of the ``git`` binary the engine resolved to.
    ##
    ## All fields participate in ``digest`` so two workspaces are not
    ## confused by the action cache when their git binary actually
    ## differs. The ``installMethod`` field mirrors the same string
    ## ``repro_tool_profiles`` writes onto a ``PathOnlyToolProfile`` so
    ## downstream consumers can correlate the identity with the active
    ## provisioning mode.
    binaryPath*: string
    version*: string
    platformOs*: string
    platformCpu*: string
    installMethod*: string
    digest*: ContentDigest

  EGitToolUnresolved* = object of CatchableError
    ## Raised when no ``git`` is reachable on the resolved tool surface
    ## (e.g. ``--tool-provisioning=path`` with no ``git`` on PATH, or a
    ## provisioning mode the engine cannot yet realize for git). The
    ## message names the active mode and the contextual reason so call
    ## sites surface actionable failures rather than silently degrading.

const
  GitExecutableName* = "git"
    ## Canonical executable name we resolve. Windows finds ``git.exe``
    ## through the standard PATHEXT-aware search in
    ## ``repro_tool_profiles``.
  GitPackageSelector* = "vcs.git"
    ## Stable selector used when constructing the synthetic
    ## ``InterfaceToolUse`` we hand to ``repro_tool_profiles``. The
    ## selector also forms part of the identity digest so collisions
    ## with other typed tools cannot occur.

  GitRepositoryLocalEnv* = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
    # These additional repository/invocation bindings are exported by some
    # Git hook and receive-pack paths even though not every Git version lists
    # them in `git rev-parse --local-env-vars`.
    "GIT_NAMESPACE",
    "GIT_QUARANTINE_PATH",
    "GIT_INTERNAL_SUPER_PREFIX"]
    ## Git variables whose values bind a child process to the invoking
    ## repository. Git exports them to hooks; they must not override an
    ## explicit `git -C <other-repository>` in cross-repository operations.

  GitRepositoryLocalEnvPrefixes* = [
    "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"]
    ## `GIT_CONFIG_COUNT` expands to an arbitrary number of indexed key/value
    ## variables, so the complete local environment cannot be a fixed list.

  GitObjectStoreEnv* = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_OBJECT_DIRECTORY",
    "GIT_QUARANTINE_PATH"]
    ## The subset of the repository-local bindings that names an OBJECT STORE
    ## rather than a repository. Scrubbing them is right for a cross-repository
    ## call (`git -C <sibling>` must not read the invoking repository's
    ## objects) and wrong for a call that operates on the invoking repository
    ## itself while its objects are still QUARANTINED.
    ##
    ## Git delivers a push's objects into a temporary quarantine directory and
    ## names it to the `pre-receive` hook through these variables; the objects
    ## are moved into the repository's own store only once the hook accepts. A
    ## `pre-receive`-time reader that drops them therefore sees a repository
    ## that does not contain the commit being pushed — every read of the pushed
    ## content comes back empty, which is indistinguishable from "the push
    ## carries nothing to check". A server-side gate built on such a reader
    ## silently accepts everything it exists to reject, so a reader that runs
    ## inside `pre-receive` must keep these three.

proc isRepositoryLocalGitEnvKey(key: string): bool =
  for candidate in GitRepositoryLocalEnv:
    if key == candidate:
      return true
  for prefix in GitRepositoryLocalEnvPrefixes:
    if key.startsWith(prefix):
      return true

proc isGitObjectStoreEnvKey*(key: string): bool =
  ## True for the object-store bindings above — the ones a `pre-receive`-time
  ## reader of the pushed content must preserve.
  for candidate in GitObjectStoreEnv:
    if key == candidate:
      return true

proc scrubbedGitRepositoryEnv*(preserveObjectStore = false): StringTableRef =
  ## Return the ambient process environment without Git's repository-local
  ## bindings. All unrelated environment entries are preserved byte-for-byte.
  ##
  ## `preserveObjectStore` keeps `GitObjectStoreEnv` — set it only for a call
  ## that reads the INVOKING repository (never a sibling) at a moment when the
  ## objects it must see live in the push quarantine rather than in the
  ## repository's own store.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if not isRepositoryLocalGitEnvKey(key) or
        (preserveObjectStore and isGitObjectStoreEnvKey(key)):
      result[key] = value

const GitReceivedObjectStoreEnv* = [
  "GIT_QUARANTINE_PATH",
  "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES"]
  ## The subset of ``GitRepositoryLocalEnv`` that names WHERE THE OBJECTS ARE
  ## during a ``receive-pack`` hook.
  ##
  ## ``receive-pack`` stages an incoming push in a QUARANTINE object directory
  ## and only migrates it into the repository once every ``pre-receive`` hook
  ## has accepted. Until then the pushed objects are reachable ONLY through
  ## these three bindings: ``GIT_OBJECT_DIRECTORY`` points at the quarantine,
  ## ``GIT_ALTERNATE_OBJECT_DIRECTORIES`` back at the repository's real store,
  ## and ``GIT_QUARANTINE_PATH`` records the staging directory. A child git run
  ## with them scrubbed cannot see the very objects the hook is being asked to
  ## judge: ``cat-file -t`` exits 128, ``ls-tree -r`` exits 128 and
  ## ``rev-parse --verify`` exits 1, for a commit that is unquestionably
  ## present.
  ##
  ## They stay in ``GitRepositoryLocalEnv`` — scrubbing them is CORRECT for the
  ## case that list exists for, a ``git -C <other-repository>`` that must not
  ## inherit the invoking repository's object store. ``receiveHookObjectStore``
  ## below names the ONE case that is not that: a hook reading ITS OWN
  ## repository, where the bindings are not an inherited accident but the only
  ## address the objects have.

type
  ReceivedObjectStore* = object
    ## A snapshot of ``GitReceivedObjectStoreEnv`` taken from the AMBIENT
    ## environment, before any scrub, so it can be put back on a child that
    ## reads the receiving repository's own received objects.
    ##
    ## ``captured`` distinguishes "there was nothing to capture" (an ordinary
    ## non-hook invocation, or a git old enough not to quarantine) from "the
    ## bindings were captured and are empty", so a caller can report the two
    ## apart instead of guessing.
    captured*: bool
    bindings*: seq[tuple[name, value: string]]

proc receiveHookObjectStore*(): ReceivedObjectStore =
  ## Capture the receive-pack object-store bindings from the ambient
  ## environment. Call this at HOOK ENTRY, before anything scrubs them.
  result.captured = false
  for name in GitReceivedObjectStoreEnv:
    if existsEnv(name):
      result.captured = true
      result.bindings.add((name: name, value: getEnv(name)))

proc withReceivedObjectStore*(env: StringTableRef;
                              store: ReceivedObjectStore): StringTableRef =
  ## Put a captured ``ReceivedObjectStore`` BACK onto an otherwise scrubbed
  ## environment. Use this ONLY for a child git that reads the receiving
  ## repository's own objects (``git -C <that same bare> …``).
  ##
  ## Never use it for a child that touches a DIFFERENT repository — a forward
  ## push to the upstream, say. There the bindings would do exactly the damage
  ## the scrubber exists to prevent, by pointing the other repository's
  ## receive side at this one's object store.
  result = env
  if result.isNil:
    result = newStringTable(modeCaseSensitive)
  if not store.captured:
    return
  for binding in store.bindings:
    result[binding.name] = binding.value

proc receivedObjectStoreEnv*(store: ReceivedObjectStore): StringTableRef =
  ## ``scrubbedGitRepositoryEnv`` plus the captured received-object bindings:
  ## the environment for a read the receiving repository makes of its own
  ## incoming objects. With nothing captured this is exactly
  ## ``scrubbedGitRepositoryEnv()``, so a non-hook caller is unaffected.
  withReceivedObjectStore(scrubbedGitRepositoryEnv(), store)

proc modeName(mode: ToolProvisioningMode): string =
  case mode
  of tpmUnspecified: "unspecified"
  of tpmPathOnly: "path"
  of tpmNix: "nix"
  of tpmTarball: "tarball"
  of tpmScoop: "scoop"
  of tpmFromSource: "from-source"

proc raiseUnresolved(mode: ToolProvisioningMode; reason: string) {.noreturn.} =
  var err = newException(EGitToolUnresolved,
    "git tool resolution failed under --tool-provisioning=" &
      modeName(mode) & ": " & reason)
  raise err

proc syntheticGitUseDef(): InterfaceToolUse =
  ## A minimal ``InterfaceToolUse`` describing git well enough for the
  ## existing ``resolvePathOnlyTool`` to drive its PATH search and
  ## sidecar lookup. No provisioning lists are populated: this M1
  ## identity helper only supports ``tpmPathOnly`` end-to-end (see the
  ## module doc comment).
  InterfaceToolUse(
    rawConstraint: GitPackageSelector,
    packageSelector: GitPackageSelector,
    executableName: GitExecutableName)

proc extractGitVersion(output: string): string =
  ## Normalize the ``git --version`` banner into the canonical
  ## ``git version X.Y.Z[.suffix]`` form. We keep the full first
  ## non-empty line so vendor builds that append ``windows.1`` or
  ## ``apple`` still produce distinct identities — the action cache
  ## must NOT confuse two such builds.
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len == 0:
      continue
    return line
  ""

proc probeGitVersion(binaryPath: string): string =
  ## Invoke ``<binary> --version`` and return the canonical first line
  ## of the banner. Raises ``EGitToolUnresolved`` if the probe exits
  ## non-zero or yields an empty output.
  let res = execCmdEx(quoteShell(binaryPath) & " --version")
  if res.exitCode != 0:
    raise newException(EGitToolUnresolved,
      "git --version exited " & $res.exitCode & " for binary " &
        binaryPath & ": " & res.output.strip())
  let normalized = extractGitVersion(res.output)
  if normalized.len == 0:
    raise newException(EGitToolUnresolved,
      "git --version emitted no recognizable banner for binary " &
        binaryPath)
  normalized

proc identityDigest(identity: GitToolIdentity): ContentDigest =
  ## Pack every identity-bearing field into a length-prefixed payload
  ## and hash it under ``hdActionFingerprint`` so the digest can be
  ## folded directly into a VCS action's fingerprint by callers in
  ## M2+. The ``reprobuild.gitToolIdentity.v1`` magic protects against
  ## future re-shapings of the identity record.
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.gitToolIdentity.v1")
  payload.writeString(GitPackageSelector)
  payload.writeString(identity.installMethod)
  payload.writeString(identity.binaryPath)
  payload.writeString(identity.version)
  payload.writeString(identity.platformOs)
  payload.writeString(identity.platformCpu)
  blake3DomainDigest(payload, hdActionFingerprint)

proc resolveGitTool*(mode: ToolProvisioningMode;
                     pathEnv: string): GitToolIdentity =
  ## Resolve git under the requested provisioning mode and return a
  ## fully-populated ``GitToolIdentity``.
  ##
  ## ``pathEnv`` carries the PATH the caller wants searched. The proc
  ## never consults the process-wide PATH for the search itself
  ## (callers that wish that behaviour can pass ``getEnv("PATH")``),
  ## but it MAY consult the process environment for the ``git
  ## --version`` subprocess — we cannot launch git without exposing
  ## some PATH-equivalent to the OS loader, and the version banner is
  ## what governs the identity.
  ##
  ## Raises ``EGitToolUnresolved`` for every failure mode the caller
  ## can plausibly act on (no git on PATH, version probe non-zero,
  ## unsupported provisioning mode). Other exceptions propagate
  ## as-is.
  case mode
  of tpmPathOnly:
    let useDef = syntheticGitUseDef()
    var profile: PathOnlyToolProfile
    try:
      profile = resolvePathOnlyTool(useDef, pathEnv)
    except OSError as exc:
      raiseUnresolved(mode, exc.msg)
    if profile.resolvedExecutablePath.len == 0:
      raiseUnresolved(mode,
        "resolvePathOnlyTool returned an empty resolved executable path")
    let version = probeGitVersion(profile.resolvedExecutablePath)
    let host = currentHost()
    result = GitToolIdentity(
      binaryPath: profile.resolvedExecutablePath,
      version: version,
      platformOs: host.os,
      platformCpu: host.cpu,
      installMethod: profile.installMethod)
    result.digest = identityDigest(result)
  of tpmNix, tpmTarball, tpmScoop, tpmFromSource:
    raiseUnresolved(mode,
      "M1 supports only --tool-provisioning=path for git; the " &
        modeName(mode) & " backend will be wired through " &
        "repro_tool_profiles in a later milestone")
  of tpmUnspecified:
    raiseUnresolved(mode,
      "no provisioning mode was selected before resolving git; " &
        "callers must parse --tool-provisioning before invoking " &
        "resolveGitTool")

proc digestHex*(identity: GitToolIdentity): string =
  ## Hex encoding of the identity digest, suitable for embedding in an
  ## action fingerprint payload or for cross-process equality checks.
  hashText.toHex(identity.digest.bytes)

proc ensureGitToolResolvable*(mode: ToolProvisioningMode;
                              pathEnv: string): GitToolIdentity =
  ## Single helper M2+ call sites consume before issuing any VCS
  ## action: it returns the resolved identity on success and raises
  ## ``EGitToolUnresolved`` with a message naming the active mode on
  ## failure. The CLI surface in ``repro_cli_support`` does NOT yet
  ## invoke this helper — that wiring is M9's responsibility. M1's
  ## scope is the library and this helper.
  resolveGitTool(mode, pathEnv)
