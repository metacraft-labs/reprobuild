## The tool profile fingerprint must be a function of WHAT WAS FOUND,
## not of WHERE WE LOOKED.
##
## ## The defect this pins
##
## ``resolvePathOnlyTool`` snapshots the verbatim host ``$PATH`` into
## ``PathOnlyToolProfile.pathSearchList``, and
## ``profileFingerprintFor`` hashed that whole list. The profile
## fingerprint flows into every typed-tool action's weak fingerprint
## (``repro_cli_support.nim``, ``reprobuild.localProjectAction`` —
## ``digestHex(profile.profileFingerprint)``), so the entire action
## cache was a function of the caller's ``$PATH`` string.
##
## Measured on the real graph before the fix: appending ONE nonexistent
## directory to the END of ``$PATH`` moved 1391 / 1391 weak
## fingerprints, while 0 tools resolved to a different executable. A
## control run with an unchanged ``$PATH`` but a different work-root and
## cache-root moved 0 / 1391, ruling those out.
##
## ## What the search list did and did not buy — and what its removal costs
##
## For the DECLARED tool the search list bought nothing. Knowing where
## the resolver looked says nothing about what it found: two hosts with
## a byte-identical ``$PATH`` can still have different ``/usr/bin/gcc``,
## and two hosts with different ``$PATH`` routinely resolve the identical
## binary. Hashing it only guaranteed that no two hosts, shells, or CI
## runs ever shared a cache entry. ``resolvedExecutableDigest`` replaces
## it with a strictly better signal for that job.
##
## It is NOT true, however, that the search list was keying nothing at
## all. ``pathSearchList`` is also threaded onto every typed-tool
## action's RUNTIME ``PATH`` (``repro_cli_support.nim`` splices it into
## ``mergedBinDirs``, which ``actionPathEntry`` turns into the action's
## ``PATH`` value), and ``PATH`` is a deliberate name-keyed PASSTHROUGH
## (``ActionPathPassthrough``) whose VALUE is never keyed. So
## ``profileFingerprint``'s copy of the search list was the only thing
## putting the host ``$PATH`` into any cache key. After this change the
## action's effective ``PATH`` — and therefore the resolution of every
## BARE-NAME sub-tool the action's command line invokes (``mkdir``,
## ``cp``, ``tr``, ``python3`` …) — is unkeyed.
##
## That is a real, measured stale-serve hole, not a theoretical one. See
## the "known gap" test below for the shape, the measurement, and why
## observed-input revalidation does not close it. Eliminating host-``$PATH``
## over-invalidation is the trade this change makes; leaving runtime
## sub-tool resolution unkeyed is what it pays.
##
## ## Why dropping it ALONE would be a worse defect
##
## ``resolvedExecutablePath`` is a path STRING, not a content identity.
## Dropping the search list without adding one would let two hosts whose
## ``/usr/bin/gcc`` differ in content key identically — trading
## over-invalidation for a stale-serve hole. So the fix pairs the
## removal with ``resolvedExecutableDigest``, a blake3 digest of the
## resolved executable's bytes, and BOTH directions are asserted here:
##
##   1. A ``$PATH`` difference that changes no resolution must NOT move
##      the fingerprint.
##   2. A resolution that finds different BYTES at the same path MUST
##      move it.
##
## Test (2) is the mutation guard on test (1): delete the digest and (2)
## fails; keep the search list and (1) fails. Neither alone is
## sufficient evidence.
##
## The same pairing applies to the two prepended-shadow cases at the end
## of the file: "shadows the declared tool ⇒ key moves" is the guard that
## keeps "shadows only sub-tools ⇒ key does not move" from passing
## vacuously on a resolver that ignored ``$PATH`` order altogether.
##
## ## No mocks
##
## Real files on the real filesystem, resolved through the real
## ``resolvePathOnlyTool`` against the real probe execution path. The
## fixture tool is a genuine executable shell script that the resolver
## actually spawns for its ``--version`` probe.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles

const FixtureToolName = "toolpath-fixture-tool"

const FixtureSubToolName = "toolpath-fixture-subtool"
  ## Stands in for the bare-name helpers a real action's command line
  ## invokes without declaring them (``mkdir``, ``cp``, ``chmod``,
  ## ``tr``, ``python3`` …). It is deliberately NOT the name any
  ## ``uses:`` entry resolves, so the resolver never looks for it — which
  ## is precisely why a directory containing it is invisible to the
  ## profile key.

proc writeExecutable(binDir, name, body: string) =
  createDir(binDir)
  let toolPath = binDir / name
  writeFile(toolPath, "#!/bin/sh\n" & body & "\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeFixtureTool(binDir, behaviour: string) =
  ## A real executable. The ``--version`` output is IDENTICAL across
  ## behaviours on purpose: the probe channel must not be what makes the
  ## content-change direction pass, otherwise that test would prove
  ## nothing about content identity.
  createDir(binDir)
  let toolPath = binDir / FixtureToolName
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then\n" &
    "  echo '" & FixtureToolName & " 1.0.0'\n" &
    "  exit 0\n" &
    "fi\n" &
    "echo '" & behaviour & "'\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc fixtureUseDef(): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: FixtureToolName,
    packageSelector: FixtureToolName,
    executableName: FixtureToolName)

suite "tool_profile_keys_on_resolution_not_search_path":
  test "a PATH entry that changes no resolution does not move the fingerprint":
    let scratch = createTempDir("repro-toolpath-search-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")

    let baseline = resolvePathOnlyTool(fixtureUseDef(), pathValue = binDir)

    # The appended directory does NOT exist and is LAST. Zero tools can
    # resolve differently — proven by construction, and re-asserted
    # below against the resolver's own answer.
    let absentDir = scratch / "this-directory-does-not-exist"
    check not dirExists(absentDir)
    let widened = resolvePathOnlyTool(fixtureUseDef(),
      pathValue = binDir & $PathSep & absentDir)

    # Precondition: nothing about the resolution changed.
    check widened.resolvedExecutablePath == baseline.resolvedExecutablePath
    check widened.resolvedExecutablePath == binDir / FixtureToolName

    # The search list itself DID change — that is the input we are
    # asserting is not keyed. Without this the test would be vacuous if
    # the resolver ever stopped recording the caller's PATH.
    check widened.pathSearchList != baseline.pathSearchList
    check absentDir in widened.pathSearchList

    check widened.profileFingerprint == baseline.profileFingerprint

  test "a PATH difference in a leading entry that still resolves the same tool does not move the fingerprint":
    # The harder shape of the same claim: the changed entry is FIRST,
    # not last, and it exists — it simply contains no matching
    # executable. A resolver that keyed on "the first entry" rather than
    # on the resolution would pass the previous test and fail this one.
    let scratch = createTempDir("repro-toolpath-leading-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")
    let emptyDir = scratch / "empty-but-real"
    createDir(emptyDir)

    let baseline = resolvePathOnlyTool(fixtureUseDef(), pathValue = binDir)
    let prefixed = resolvePathOnlyTool(fixtureUseDef(),
      pathValue = emptyDir & $PathSep & binDir)

    check prefixed.resolvedExecutablePath == baseline.resolvedExecutablePath
    check prefixed.pathSearchList != baseline.pathSearchList
    check prefixed.profileFingerprint == baseline.profileFingerprint

  test "different bytes at the same resolved path MUST move the fingerprint":
    # The paired direction, and the guard that stops the fix above from
    # trading over-invalidation for a stale-serve hole. Same path, same
    # ``--version`` probe output, different executable content.
    let scratch = createTempDir("repro-toolpath-content-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")
    let before = resolvePathOnlyTool(fixtureUseDef(), pathValue = binDir)

    writeFixtureTool(binDir, "BEHAVIOUR-B")
    let after = resolvePathOnlyTool(fixtureUseDef(), pathValue = binDir)

    # Everything a path-string key can see is unchanged.
    check after.resolvedExecutablePath == before.resolvedExecutablePath
    check after.pathSearchList == before.pathSearchList
    check after.probes.len == before.probes.len
    check after.probes.len == 1
    check after.probes[0].output == before.probes[0].output

    # Only the bytes differ — and that must be enough.
    check after.resolvedExecutableDigest.len > 0
    check after.resolvedExecutableDigest != before.resolvedExecutableDigest
    check after.profileFingerprint != before.profileFingerprint

  test "two hosts' same-named tool at different paths keep distinct fingerprints":
    # The cross-host case the search list was mistakenly credited with
    # covering: the same tool name resolving out of two different
    # directories with different content.
    let scratch = createTempDir("repro-toolpath-distinct-", "")
    defer: removeDir(scratch)

    let binA = scratch / "host-a" / "bin"
    let binB = scratch / "host-b" / "bin"
    writeFixtureTool(binA, "BEHAVIOUR-A")
    writeFixtureTool(binB, "BEHAVIOUR-B")

    let a = resolvePathOnlyTool(fixtureUseDef(), pathValue = binA)
    let b = resolvePathOnlyTool(fixtureUseDef(), pathValue = binB)

    check a.resolvedExecutablePath != b.resolvedExecutablePath
    check a.resolvedExecutableDigest != b.resolvedExecutableDigest
    check a.profileFingerprint != b.profileFingerprint

  test "identical bytes at two different paths still key distinctly":
    # Content identity does not REPLACE the resolved path — a tool found
    # at a different absolute path is still a different action
    # invocation (the argv carries the path), so the key must move.
    let scratch = createTempDir("repro-toolpath-samebytes-", "")
    defer: removeDir(scratch)

    let binA = scratch / "a" / "bin"
    let binB = scratch / "b" / "bin"
    writeFixtureTool(binA, "BEHAVIOUR-A")
    writeFixtureTool(binB, "BEHAVIOUR-A")

    let a = resolvePathOnlyTool(fixtureUseDef(), pathValue = binA)
    let b = resolvePathOnlyTool(fixtureUseDef(), pathValue = binB)

    check a.resolvedExecutableDigest == b.resolvedExecutableDigest
    check a.resolvedExecutablePath != b.resolvedExecutablePath
    check a.profileFingerprint != b.profileFingerprint

  test "the action identity carries the same content digest as its profile":
    # ``actionFingerprintFor`` keys a second, parallel structure. If the
    # digest reached the profile but not the action identity, the action
    # fingerprint would still be blind to content.
    let scratch = createTempDir("repro-toolpath-action-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")

    let useDef = fixtureUseDef()
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "toolpathFixture",
        toolUses: @[useDef]))

    let absentDir = scratch / "absent"
    let first = toolBuildIdentity(artifact, tpmPathOnly, pathValue = binDir)
    let widened = toolBuildIdentity(artifact, tpmPathOnly,
      pathValue = binDir & $PathSep & absentDir)

    check first.actionIdentities.len == 1
    check first.actionIdentities[0].resolvedExecutableDigest ==
      first.profiles[0].resolvedExecutableDigest
    check first.actionIdentities[0].resolvedExecutableDigest.len > 0

    # Direction 1 at the action-identity level.
    check widened.actionIdentities[0].actionFingerprint ==
      first.actionIdentities[0].actionFingerprint

    # Direction 2 at the action-identity level.
    writeFixtureTool(binDir, "BEHAVIOUR-B")
    let changed = toolBuildIdentity(artifact, tpmPathOnly, pathValue = binDir)
    check changed.actionIdentities[0].resolvedExecutablePath ==
      first.actionIdentities[0].resolvedExecutablePath
    check changed.actionIdentities[0].actionFingerprint !=
      first.actionIdentities[0].actionFingerprint

  test "the resolved-executable digest survives the identity artifact round-trip":
    # The digest is a KEY input, so it has to be in the persisted
    # artifact. A field that is fingerprinted but not serialized would
    # make a cached identity re-hash to a different fingerprint on
    # every read.
    let scratch = createTempDir("repro-toolpath-roundtrip-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")

    let useDef = fixtureUseDef()
    let artifact = ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(
        projectName: "toolpathFixture",
        toolUses: @[useDef]))
    let identity = toolBuildIdentity(artifact, tpmPathOnly,
      pathValue = binDir)

    let artifactPath = scratch / "identity.rbtp"
    writePathOnlyBuildIdentity(artifactPath, identity)
    let reread = readPathOnlyBuildIdentity(artifactPath)

    check reread.profiles.len == 1
    check reread.profiles[0].resolvedExecutableDigest ==
      identity.profiles[0].resolvedExecutableDigest
    check reread.profiles[0].resolvedExecutableDigest.len > 0
    check reread.profiles[0].profileFingerprint ==
      identity.profiles[0].profileFingerprint
    check reread.actionIdentities[0].resolvedExecutableDigest ==
      identity.actionIdentities[0].resolvedExecutableDigest
    check reread.actionIdentities[0].actionFingerprint ==
      identity.actionIdentities[0].actionFingerprint

  test "a prepended EXISTING directory that shadows the tool moves the fingerprint":
    # The only ``$PATH`` shape that can change what the resolver returns:
    # the changed entry is FIRST, it EXISTS, and it CONTAINS a matching
    # executable. Every other PATH case in this file uses a directory
    # that is absent or empty, so without this one the "a PATH entry that
    # changes no resolution does not move the fingerprint" pair would
    # also pass on a resolver that ignored ``$PATH`` order — or ignored
    # ``$PATH`` entirely. This is that pair's non-vacuity guard.
    let scratch = createTempDir("repro-toolpath-shadow-tool-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")
    let shadowDir = scratch / "shadow-bin"
    writeFixtureTool(shadowDir, "BEHAVIOUR-SHADOW")

    let baseline = resolvePathOnlyTool(fixtureUseDef(), pathValue = binDir)
    let shadowed = resolvePathOnlyTool(fixtureUseDef(),
      pathValue = shadowDir & $PathSep & binDir)

    # Precondition: the prepend really did win the resolution.
    check baseline.resolvedExecutablePath == binDir / FixtureToolName
    check shadowed.resolvedExecutablePath == shadowDir / FixtureToolName

    check shadowed.resolvedExecutableDigest != baseline.resolvedExecutableDigest
    check shadowed.profileFingerprint != baseline.profileFingerprint

  test "a prepended EXISTING directory that shadows only UNDECLARED sub-tools does not move the fingerprint":
    # KNOWN GAP — this test pins current behaviour and documents it as a
    # hole, not as a property worth having.
    #
    # The prepended directory is real, is FIRST, and holds a real
    # executable. It just isn't the DECLARED tool, so the resolver never
    # looks for it and the profile key cannot see it. Meanwhile that same
    # directory does reach the action: ``pathSearchList`` is spliced into
    # the action's runtime ``PATH`` by ``repro_cli_support.nim``, and
    # ``PATH`` is a name-keyed passthrough whose value is never
    # fingerprinted. So a bare-name sub-tool the action's command line
    # invokes resolves out of this directory at execution time with
    # nothing keying that choice.
    #
    # MEASURED END TO END on a one-action project whose ``sh -c`` command
    # invokes bare ``tr``, same work-root and cache-root across runs:
    #
    #   run 1  unchanged PATH                         cdMiss, executed, out="HELLO"
    #   run 2  unchanged PATH                         cdHit,  not executed, out="HELLO"
    #   run 3  prepend dir shadowing NOTHING          cdHit,  not executed, out="HELLO"
    #   run 4  prepend dir containing a fake ``tr``   cdHit,  not executed, out="HELLO"
    #   run 5  same PATH as run 4, --force-rebuild    executed,             out="SHADOWED"
    #
    # Run 4 served bytes that the action, run for real under that exact
    # ``$PATH``, would not have produced. Run 3 is the control that says
    # a prepend which shadows nothing must not invalidate — and does not.
    #
    # BuildXL-style observed-input revalidation does not rescue run 4,
    # and the reason is worth stating precisely because revalidation is
    # NOT broken — it is simply blind to this particular change.
    #
    # The monitor does record the shell's ``$PATH`` walk, as ``path-probe``
    # records with ``prAbsent`` / ``prExistingOther`` results, and those
    # do get revalidated. Measured on the same project with the extra
    # directory ON ``$PATH`` for the recording run:
    #
    #   A  dir on PATH but EMPTY, forced execution   executed, out="HELLO"
    #   B  same PATH, dir now holds a fake ``tr``    cdMiss, RE-EXECUTED,
    #                                                out="SHADOWED2"
    #
    # So a directory that a previous execution actually walked is
    # covered. What run 4 does is different: it ADDS a directory to
    # ``$PATH``, and no prior execution ever probed it, so there is no
    # recorded observation to re-check. The probes that were recorded in
    # run 1 name the real coreutils under ``/nix/store`` — and those are
    # dropped anyway, because ``cacheInputPaths`` filters out everything
    # under the action's own ``toolInputRoots``. Revalidation can only
    # re-check paths a previous execution observed; a newly prepended
    # directory is by construction not one of them.
    #
    # Closing this needs the action's runtime ``PATH`` to stop inheriting
    # the host's — i.e. a hermetic action ``PATH`` built only from
    # resolved tool directories — or the sub-tool set to be declared and
    # resolved like first-class tools. Both are larger than this change.
    let scratch = createTempDir("repro-toolpath-shadow-subtool-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")

    # Real directory, real executable inside it, prepended — and it
    # shadows a sub-tool rather than the declared tool.
    let shadowDir = scratch / "shadow-bin"
    writeExecutable(shadowDir, FixtureSubToolName, "echo SHADOWED")
    check fileExists(shadowDir / FixtureSubToolName)
    check not fileExists(shadowDir / FixtureToolName)

    let baseline = resolvePathOnlyTool(fixtureUseDef(), pathValue = binDir)
    let widened = resolvePathOnlyTool(fixtureUseDef(),
      pathValue = shadowDir & $PathSep & binDir)

    # The declared tool resolves identically — correctly so.
    check widened.resolvedExecutablePath == baseline.resolvedExecutablePath
    check widened.resolvedExecutableDigest == baseline.resolvedExecutableDigest

    # The search list DID change, and the new entry is the one that will
    # win any bare-name lookup the action performs at runtime. Without
    # these two the assertion below would be vacuous.
    check widened.pathSearchList != baseline.pathSearchList
    check widened.pathSearchList[0] == shadowDir

    # Current behaviour, pinned: the key does not move. That is the gap.
    check widened.profileFingerprint == baseline.profileFingerprint
