## Workspace VCS — typed identity for ``hg`` (Phase 1 / M3).
##
## This module mirrors ``git_tool`` (M1) for Mercurial: it establishes a
## stable, per-host ``HgToolIdentity`` that participates in action
## fingerprints whenever a hg-flavored VCS action is in play. A
## workspace built against hg 6.5 and the same workspace built against
## hg 6.9 must not be confused by the action cache when their behaviour
## actually depends on the hg version, so the identity captures the
## binary path, the version banner reported by ``hg --version``, and
## the declared host platform (OS + CPU). All three feed a single
## content digest comparable across processes.
##
## The module reuses ``repro_tool_profiles`` for tool surfacing so we
## do NOT introduce a parallel mechanism. As with M1, only the
## ``tpmPathOnly`` provisioning mode is wired end-to-end; future
## milestones will extend the same identity helper to ``tpmNix``,
## ``tpmTarball`` and ``tpmScoop`` once a first-class hg acquisition
## plan is declared. Until then those modes raise ``EHgToolUnresolved``
## with a clear message naming the active ``--tool-provisioning=`` mode.
##
## The identity's binary envelope magic is
## ``reprobuild.hgToolIdentity.v1`` (parallel to M1's
## ``reprobuild.gitToolIdentity.v1``) so a hg identity digest can never
## be confused with a git identity digest even when every other
## identity-bearing field happens to match byte-for-byte.

import std/[os, osproc, strutils]

import repro_core/codec
import repro_hash
import repro_hash/text as hashText
import repro_interface_artifacts
import repro_platform
import repro_tool_profiles

export ToolProvisioningMode

type
  HgToolIdentity* = object
    ## Per-host identity of the ``hg`` binary the engine resolved to.
    ##
    ## All fields participate in ``digest`` so two workspaces are not
    ## confused by the action cache when their hg binary actually
    ## differs. ``installMethod`` mirrors the string
    ## ``repro_tool_profiles`` writes onto a ``PathOnlyToolProfile`` so
    ## downstream consumers can correlate the identity with the active
    ## provisioning mode.
    binaryPath*: string
    version*: string
    platformOs*: string
    platformCpu*: string
    installMethod*: string
    digest*: ContentDigest

  EHgToolUnresolved* = object of CatchableError
    ## Raised when no ``hg`` is reachable on the resolved tool surface
    ## (e.g. ``--tool-provisioning=path`` with no ``hg`` on PATH, or a
    ## provisioning mode the engine cannot yet realize for hg). The
    ## message names the active mode and the contextual reason so call
    ## sites surface actionable failures rather than silently degrading.

const
  HgExecutableName* = "hg"
    ## Canonical executable name we resolve. Windows finds ``hg.exe``
    ## through the standard PATHEXT-aware search in
    ## ``repro_tool_profiles``.
  HgPackageSelector* = "vcs.hg"
    ## Stable selector used when constructing the synthetic
    ## ``InterfaceToolUse`` we hand to ``repro_tool_profiles``. The
    ## selector also forms part of the identity digest so collisions
    ## with other typed tools cannot occur.

proc modeName(mode: ToolProvisioningMode): string =
  case mode
  of tpmUnspecified: "unspecified"
  of tpmPathOnly: "path"
  of tpmNix: "nix"
  of tpmTarball: "tarball"
  of tpmScoop: "scoop"
  of tpmFromSource: "from-source"

proc raiseUnresolved(mode: ToolProvisioningMode; reason: string) {.noreturn.} =
  var err = newException(EHgToolUnresolved,
    "hg tool resolution failed under --tool-provisioning=" &
      modeName(mode) & ": " & reason)
  raise err

proc syntheticHgUseDef(): InterfaceToolUse =
  ## A minimal ``InterfaceToolUse`` describing hg well enough for the
  ## existing ``resolvePathOnlyTool`` to drive its PATH search and
  ## sidecar lookup. No provisioning lists are populated: this M3
  ## identity helper only supports ``tpmPathOnly`` end-to-end (see the
  ## module doc comment).
  InterfaceToolUse(
    rawConstraint: HgPackageSelector,
    packageSelector: HgPackageSelector,
    executableName: HgExecutableName)

proc extractHgVersion(output: string): string =
  ## Normalize the ``hg --version`` banner into a single canonical
  ## first non-empty line. Mercurial's banner is a multi-line block
  ## starting with ``Mercurial Distributed SCM (version X.Y.Z)``; we
  ## keep the full first non-empty line so distro builds that decorate
  ## the version (e.g. ``+20240101``) still produce distinct
  ## identities — the action cache must NOT confuse two such builds.
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len == 0:
      continue
    return line
  ""

proc probeHgVersion(binaryPath: string): string =
  ## Invoke ``<binary> --version`` and return the canonical first line
  ## of the banner. Raises ``EHgToolUnresolved`` if the probe exits
  ## non-zero or yields an empty output.
  let res = execCmdEx(quoteShell(binaryPath) & " --version")
  if res.exitCode != 0:
    raise newException(EHgToolUnresolved,
      "hg --version exited " & $res.exitCode & " for binary " &
        binaryPath & ": " & res.output.strip())
  let normalized = extractHgVersion(res.output)
  if normalized.len == 0:
    raise newException(EHgToolUnresolved,
      "hg --version emitted no recognizable banner for binary " &
        binaryPath)
  normalized

proc identityDigest(identity: HgToolIdentity): ContentDigest =
  ## Pack every identity-bearing field into a length-prefixed payload
  ## and hash it under ``hdActionFingerprint`` so the digest can be
  ## folded directly into a VCS action's fingerprint by callers in
  ## ``hg_actions``. The ``reprobuild.hgToolIdentity.v1`` magic
  ## protects against future re-shapings of the identity record AND
  ## guarantees a hg identity can never collide with a git identity
  ## (which carries the parallel ``reprobuild.gitToolIdentity.v1``
  ## envelope) — the magic is the first field of the hashed payload.
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.hgToolIdentity.v1")
  payload.writeString(HgPackageSelector)
  payload.writeString(identity.installMethod)
  payload.writeString(identity.binaryPath)
  payload.writeString(identity.version)
  payload.writeString(identity.platformOs)
  payload.writeString(identity.platformCpu)
  blake3DomainDigest(payload, hdActionFingerprint)

proc resolveHgTool*(mode: ToolProvisioningMode;
                    pathEnv: string): HgToolIdentity =
  ## Resolve hg under the requested provisioning mode and return a
  ## fully-populated ``HgToolIdentity``.
  ##
  ## ``pathEnv`` carries the PATH the caller wants searched. The proc
  ## never consults the process-wide PATH for the search itself
  ## (callers that wish that behaviour can pass ``getEnv("PATH")``),
  ## but it MAY consult the process environment for the ``hg
  ## --version`` subprocess — we cannot launch hg without exposing
  ## some PATH-equivalent to the OS loader, and the version banner is
  ## what governs the identity.
  ##
  ## Raises ``EHgToolUnresolved`` for every failure mode the caller
  ## can plausibly act on (no hg on PATH, version probe non-zero,
  ## unsupported provisioning mode). Other exceptions propagate
  ## as-is.
  case mode
  of tpmPathOnly:
    let useDef = syntheticHgUseDef()
    var profile: PathOnlyToolProfile
    try:
      profile = resolvePathOnlyTool(useDef, pathEnv)
    except OSError as exc:
      raiseUnresolved(mode, exc.msg)
    if profile.resolvedExecutablePath.len == 0:
      raiseUnresolved(mode,
        "resolvePathOnlyTool returned an empty resolved executable path")
    let version = probeHgVersion(profile.resolvedExecutablePath)
    let host = currentHost()
    result = HgToolIdentity(
      binaryPath: profile.resolvedExecutablePath,
      version: version,
      platformOs: host.os,
      platformCpu: host.cpu,
      installMethod: profile.installMethod)
    result.digest = identityDigest(result)
  of tpmNix, tpmTarball, tpmScoop, tpmFromSource:
    raiseUnresolved(mode,
      "M3 supports only --tool-provisioning=path for hg; the " &
        modeName(mode) & " backend will be wired through " &
        "repro_tool_profiles in a later milestone")
  of tpmUnspecified:
    raiseUnresolved(mode,
      "no provisioning mode was selected before resolving hg; " &
        "callers must parse --tool-provisioning before invoking " &
        "resolveHgTool")

proc digestHex*(identity: HgToolIdentity): string =
  ## Hex encoding of the identity digest, suitable for embedding in an
  ## action fingerprint payload or for cross-process equality checks.
  hashText.toHex(identity.digest.bytes)

proc ensureHgToolResolvable*(mode: ToolProvisioningMode;
                             pathEnv: string): HgToolIdentity =
  ## Single helper M3+ call sites consume before issuing any hg-flavored
  ## VCS action: returns the resolved identity on success and raises
  ## ``EHgToolUnresolved`` with a message naming the active mode on
  ## failure. Mirrors M1's ``ensureGitToolResolvable``.
  resolveHgTool(mode, pathEnv)
