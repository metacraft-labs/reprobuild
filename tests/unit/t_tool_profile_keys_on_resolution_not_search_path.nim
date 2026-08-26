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
## all. ``pathSearchList`` was ALSO threaded onto every typed-tool
## action's RUNTIME ``PATH``, and ``PATH`` was a deliberate name-keyed
## PASSTHROUGH whose VALUE was never keyed. So ``profileFingerprint``'s
## copy of the search list was, for a while, the only thing putting the
## host ``$PATH`` into any cache key, and removing it left the
## resolution of every BARE-NAME sub-tool an action's command line
## invokes (``mkdir``, ``cp``, ``tr``, ``python3`` …) unkeyed. That was
## a measured stale-serve hole:
##
##   T   prepend a dir that shadows bare ``tr``   cdHit,  out="HELLO"
##   T'  same ``$PATH``, ``--force-rebuild``      cdMiss, out="SHADOWED"
##
## The debt is now paid rather than merely recorded, FOR EVERY EDGE THAT
## DECLARES WHAT IT RUNS. Such an edge's runtime ``PATH`` does not
## inherit the host's at all: it is composed only of the directories the
## solved graph resolved THIS EDGE's tool and THIS EDGE's declared
## ``toolIdentityRefs`` into (``toolPathPrefix`` / ``actionPathEntry``,
## asserted below through ``actionPathEnvEntry``), and because that value
## is graph-derived it is DECLARED rather than passthrough and is keyed
## by value. A prepended directory that shadows a sub-tool is therefore
## not merely "not invalidated" — it is not on the action's ``PATH``
## at all.
##
## ## THE BOUNDARY IS THE DECLARATION, AND IT HAS TO BE
##
## An edge that declares NO tool refs takes the other branch of
## ``actionPathDecision``: it inherits the caller's ``$PATH`` and says so
## by naming ``PATH`` passthrough. For a while it did neither — it was
## given ``PATH=`` — and the measurement is in the suite at the bottom of
## this file. The two ends of that:
##
##   1372/2753 process edges on this repository's ``test`` graph carried
##   ``PATH=`` (empty), all of them ``reprobuild.test_execute.*``;
##   ``repro build '.#test#t_workspace_root_for_repo_managed_worktree'``
##   answered ``findExe("git") == ""`` by SKIPPING and reporting
##   ``asSucceeded exit=0``, then ``cdHit`` on the next run.
##
## Making those edges hermetic instead was measured and rejected: 504 of
## the 1372 registered Nim test sources call
## ``findExe``/``execCmdEx``/``execCmd``/``execProcess``/``startProcess``/``poUsePath``,
## naming ~80 distinct host tools in ``findExe`` literals alone (``git``
## in 441 of them), against ten declared tool packages — and the corpus's
## idiom is ``if findExe(x).len == 0: skip()``, so a hermetic ``PATH``
## converts those tests to silent skips rather than to loud failures.
##
## Re-measured on the same 1399-action graph after the fix, same
## instrument (``repro graph --view=actions --format=json``), isolated
## work-root and cache-root per run:
##
##   control    same $PATH, different work-root+cache   0 / 1399 moved
##   treatment  ONE NONEXISTENT dir appended at END     0 / 1399 moved
##   treatment  an EXISTING dir prepended that shadows
##              nothing any edge invokes                0 / 1399 moved
##
## and on the one-action ``tr`` project, with the sub-tool DECLARED as a
## ref (so the shadow is reachable at all), what used to be row T:
##
##   prepend a dir shadowing NOTHING       cdHit,  not executed, "HELLO"
##   prepend a dir holding a fake ``tr``   cdMiss, RE-EXECUTED,  "SHADOWED"
##   same $PATH, ``--force-rebuild``       cdMiss, executed,     "SHADOWED"
##
## The last two now agree, which is the whole point: the cached answer
## is the answer the action would produce.
##
## The cost is that a bare-name sub-tool the EDGE does not name is an
## UNDECLARED HOST-TOOL DEPENDENCY and now fails loudly at execution.
## Enumerated on this repository's own 1399-action graph, all three
## found by running the edge rather than by reading:
##
##   * ``gcc`` — 1397 ``nim c`` edges shell out to a bare C compiler.
##     26 declared it (the ``nim.c`` wrapper); the other 1371 come from
##     ``buildNimUnittest.build`` and did not.
##   * ``mkdir`` / ``cp`` / ``chmod`` — the ``reprobuild-nix-daemon``
##     staging ``shell(...)`` edge.
##   * ``python3`` — the ``generate_legacy_cache_peer_wire``
##     ``shell(...)`` edge. ``python3`` was in the package's ``uses:``
##     list, which is NOT a declaration for this purpose: a ``uses:``
##     entry says the project may need the tool, a ref says this edge
##     runs it.
##
## Each is now named at its call site.
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

import std/[options, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
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

  test "a prepended EXISTING directory that shadows only UNDECLARED sub-tools cannot reach the action at all":
    # THE GAP THIS FILE USED TO DOCUMENT, NOW CLOSED — and closed in the
    # stronger of the two available ways.
    #
    # The prepended directory is real, is FIRST, and holds a real
    # executable. It just isn't the DECLARED tool, so the resolver never
    # looks for it and the profile key cannot see it. That much is
    # unchanged, and it is correct: where the resolver looked is not
    # what it found.
    #
    # What changed is the OTHER half. That directory used to reach the
    # action anyway — ``pathSearchList`` was spliced into the action's
    # runtime ``PATH``, and ``PATH`` was a name-keyed passthrough whose
    # value was never fingerprinted — so a bare-name sub-tool the
    # action's command line invokes resolved out of it at execution time
    # with nothing keying the choice. MEASURED, on a one-action project
    # whose ``sh -c`` command invokes bare ``tr``, same work-root and
    # cache-root across runs:
    #
    #   1  unchanged PATH                         cdMiss, executed,     "HELLO"
    #   2  unchanged PATH                         cdHit,  not executed, "HELLO"
    #   3  prepend dir shadowing NOTHING          cdHit,  not executed, "HELLO"
    #   T  prepend dir containing a fake ``tr``   cdHit,  not executed, "HELLO"
    #   T' same PATH as T, --force-rebuild        cdMiss, executed,     "SHADOWED"
    #
    # Row T served bytes the action, run for real under that exact
    # ``$PATH``, would not have produced. Row 3 is the control: a
    # prepend that shadows nothing must not invalidate, and does not.
    #
    # Observed-input revalidation could not rescue row T, and the reason
    # is worth keeping because revalidation is NOT broken — it is blind
    # to this one change. The monitor does record the shell's ``$PATH``
    # walk as ``path-probe`` records and does revalidate them; a
    # directory a previous execution actually walked is covered.
    # Row T ADDS a directory, which no prior execution probed, so there
    # is no observation to re-check. The probes that were recorded name
    # the real coreutils under ``/nix/store``, which ``cacheInputPaths``
    # drops as the action's own ``toolInputRoots``.
    #
    # The fix is not "invalidate on row T". It is that row T's directory
    # is no longer on the action's ``PATH``: ``actionPathEntry`` composes
    # the value out of resolved tool directories only, with no host tail,
    # so the shadow cannot influence the action whether or not the key
    # moves. That is the second of the two sound outcomes and the better
    # one — the first (re-execute) still leaves the host deciding what
    # runs.
    #
    # THE FINGERPRINT ASSERTION BELOW IS THEREFORE STILL "DOES NOT MOVE",
    # and that is now a property rather than a gap: nothing about the
    # resolution changed, so nothing about the key should. The assertion
    # that carries the fix is the ``actionPathEnvEntry`` pair after it.
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

    # The search list DID change, and under the old composition its new
    # entry was the one that won every bare-name lookup the action
    # performed at runtime. Without these two, both assertions below
    # would be vacuous — a resolver that had stopped recording the
    # caller's ``$PATH`` would satisfy them for the wrong reason.
    check widened.pathSearchList != baseline.pathSearchList
    check widened.pathSearchList[0] == shadowDir

    # Where the resolver looked is not a key input. Unchanged, and right.
    check widened.profileFingerprint == baseline.profileFingerprint

    # THE HALF THAT CLOSES THE HOLE. The action's whole runtime ``PATH``,
    # composed from the same widened profile, contains the directory the
    # declared tool was resolved out of and NOTHING ELSE — in particular
    # not the prepended shadow directory, and not any other entry of the
    # caller's ``$PATH``.
    let entry = actionPathEnvEntry(@[widened],
      packageName = FixtureToolName, executableName = FixtureToolName)
    checkpoint("composed action PATH entry: " & entry)
    check entry == "PATH=" & binDir
    check not entry.contains(shadowDir)

    # ... and the same holds for the un-widened resolution, so the two
    # differ in nothing: the caller's ``$PATH`` is not a term in the
    # composition at all.
    check actionPathEnvEntry(@[baseline],
      packageName = FixtureToolName, executableName = FixtureToolName) == entry

  test "the composed action PATH is a function of the resolved tools alone":
    # The non-vacuity guard for the pair above, in the direction that
    # matters: the composition is not simply constant. A tool resolved
    # out of a DIFFERENT directory must produce a different ``PATH``, and
    # a second declared tool must contribute its own directory. Without
    # this, an ``actionPathEnvEntry`` that returned a fixed string would
    # satisfy every assertion above.
    let scratch = createTempDir("repro-toolpath-compose-", "")
    defer: removeDir(scratch)

    let binA = scratch / "a" / "bin"
    let binB = scratch / "b" / "bin"
    writeFixtureTool(binA, "BEHAVIOUR-A")
    writeFixtureTool(binB, "BEHAVIOUR-B")

    let a = resolvePathOnlyTool(fixtureUseDef(), pathValue = binA)
    let b = resolvePathOnlyTool(fixtureUseDef(), pathValue = binB)
    check actionPathEnvEntry(@[a], packageName = FixtureToolName,
      executableName = FixtureToolName) !=
      actionPathEnvEntry(@[b], packageName = FixtureToolName,
        executableName = FixtureToolName)

    # A SECOND RESOLVED TOOL JOINS ONLY WHEN THE EDGE NAMES IT.
    #
    # This pair is the boundary of the whole change, so it is asserted in
    # both directions. The permissive alternative — splice in every tool
    # the project resolved, named or not — was implemented, measured, and
    # removed: `profiles` holds the identities REALIZED for the
    # invocation, and `scopedToolArtifact` narrows realization to what the
    # SELECTED actions reference, so a union would make an action's PATH
    # (and now its cache key) depend on what else the invocation
    # selected. It also hid the missing declarations: a whole-graph build
    # passed while `repro build <one nim test edge>` failed with
    # `gcc: command not found`.
    let subBin = scratch / "sub" / "bin"
    writeExecutable(subBin, FixtureSubToolName, "echo SUB")
    let subUse = InterfaceToolUse(
      rawConstraint: FixtureSubToolName,
      packageSelector: FixtureSubToolName,
      executableName: FixtureSubToolName)
    let sub = resolvePathOnlyTool(subUse, pathValue = subBin)

    # Resolved but UNNAMED: absent.
    let unnamed = actionPathEnvEntry(@[a, sub], packageName = FixtureToolName,
      executableName = FixtureToolName)
    checkpoint("resolved-but-unnamed PATH entry: " & unnamed)
    check unnamed == "PATH=" & binA
    check not unnamed.contains(subBin)

    # NAMED as a ref: present, after the edge's own tool.
    let named = actionPathEnvEntry(@[a, sub], packageName = FixtureToolName,
      executableName = FixtureToolName, refs = [FixtureSubToolName])
    checkpoint("named-ref PATH entry: " & named)
    check named == "PATH=" & binA & $PathSep & subBin

suite "the fork-time PATH overlay excludes the host search list":
  # ``actionPathEntry`` composes what the LOWERING writes into
  # ``action.env``. It is not the only contributor to what the child
  # process finally sees: at fork time the engine walks each action's
  # ``toolIdentityRefs`` through ``mkToolIdentityResolver``'s closure and
  # PREPENDS the resolved ``binDirs`` to that value. A hermetic
  # ``action.env`` with a leaky overlay would be no hermeticity at all —
  # and the overlay was the leakier of the two, because it put the host
  # directories AHEAD of the store ones rather than behind them.

  proc pathAdapterIdentity(resolved, hostA, hostB: string):
      PathOnlyBuildIdentity =
    PathOnlyBuildIdentity(actionIdentities: @[
      ToolActionIdentity(
        installMethod: "path",
        packageSelector: FixtureToolName,
        executableName: FixtureToolName,
        resolvedExecutablePath: resolved,
        # What ``resolvePathOnlyTool`` records for this adapter: the
        # caller's whole ``$PATH``, not a list of tool directories.
        pathSearchList: @[hostA, hostB])])

  test "a path-adapter identity contributes only its resolved directory":
    let scratch = createTempDir("repro-toolpath-overlay-path-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")
    let hostA = scratch / "host-a"
    let hostB = scratch / "host-b"
    createDir(hostA)
    createDir(hostB)

    let resolver = mkToolIdentityResolver(
      pathAdapterIdentity(binDir / FixtureToolName, hostA, hostB))
    let resolved = resolver(FixtureToolName, dkBuild)
    check resolved.isSome
    checkpoint("binDirs: " & $resolved.get().binDirs)
    check resolved.get().binDirs == @[binDir]
    check hostA notin resolved.get().binDirs
    check hostB notin resolved.get().binDirs

  test "a nix-adapter identity still contributes its whole search list":
    # The non-vacuity guard. The fallback is not dead code: for every
    # adapter that BUILDS a search list out of realized store paths, the
    # list is graph-derived and is exactly what belongs on the action's
    # PATH. A fix that dropped it unconditionally would pass the case
    # above and silently strip the store bin dirs of every nix, tarball,
    # scoop and from-source tool.
    let scratch = createTempDir("repro-toolpath-overlay-nix-", "")
    defer: removeDir(scratch)

    let storeBin = scratch / "store" / "bin"
    let extraBin = scratch / "store-extra" / "bin"
    createDir(storeBin)
    createDir(extraBin)

    var identity = pathAdapterIdentity(storeBin / FixtureToolName,
      storeBin, extraBin)
    identity.actionIdentities[0].installMethod = "nix"

    let resolver = mkToolIdentityResolver(identity)
    let resolved = resolver(FixtureToolName, dkBuild)
    check resolved.isSome
    checkpoint("binDirs: " & $resolved.get().binDirs)
    check resolved.get().binDirs == @[storeBin, extraBin]

suite "an action's PATH is a decision, and it is never the empty string":
  ## THE GATE THAT WAS MISSING WHEN `PATH=` SHIPPED.
  ##
  ## Reverting `actionPathDecision` to the unconditional
  ## `env.add(actionPathEntry(prefix))` that preceded it left every case
  ## in this file and in
  ## `libs/repro_build_engine/tests/t_declared_env_is_in_the_cache_key.nim`
  ## green — 12/12 and 10/10 — while 1372 of 2753 process edges carried
  ## an empty `PATH`. Nothing in the test surface could see the
  ## difference, because every case asserted the COMPOSITION
  ## (`actionPathEnvEntry`) and none asserted the EMISSION. These do.
  ##
  ## Each case below is mutation-tested against the real module; the
  ## mutations and their outcomes are recorded in the commit message.

  proc fixtureDir(scratch: string): string =
    let binDir = scratch / "bin"
    writeFixtureTool(binDir, "BEHAVIOUR-A")
    binDir

  test "a declaring edge gets a hermetic PATH, keyed by value":
    let scratch = createTempDir("repro-toolpath-decide-hermetic-", "")
    defer: removeDir(scratch)
    let binDir = fixtureDir(scratch)

    let decision = actionPathDecision(binDir, edgeDeclaresTools = true)
    checkpoint("env: " & $decision.env &
      " passthrough: " & $decision.passthrough)
    check decision.class == apcHermetic
    check decision.env == @["PATH=" & binDir]
    # Keyed BY VALUE: no passthrough name, so
    # `keyedOnActionEnvironment` records `PATH=<value>` rather than the
    # bare name. This is the half `7823baae8` bought and the half that
    # must survive the D1 fix.
    check decision.passthrough.len == 0
    # ... and the host's `$PATH` is not a term in it. The dev shell that
    # runs this test has a long `$PATH`; none of it may appear.
    for entry in getEnv("PATH").split($PathSep):
      if entry.len == 0 or entry == binDir:
        continue
      check not decision.env[0].contains(entry)

  test "a non-declaring edge with nothing resolved emits NO PATH entry":
    # The branch the 1372 `reprobuild.test_execute.*` edges take, and
    # the one D1 broke. Before `actionPathDecision` these got `PATH=` —
    # which, per `prependPathDirsToArgvEnv`, REPLACES the inherited
    # value rather than falling through to it. The fix is not to emit
    # the host value here but to emit NOTHING, so the launcher's own
    # `getEnv("PATH")` fallback reads the CURRENT shell rather than
    # whatever the lowered-graph cache snapshotted on some earlier run.
    let decision = actionPathDecision("", edgeDeclaresTools = false)
    checkpoint("env: " & $decision.env &
      " passthrough: " & $decision.passthrough)
    check decision.class == apcInherited
    check decision.env.len == 0
    # Emitting nothing is what the base commit did too. What is new is
    # this: the name is in the key even though the value is not, so the
    # edge SAYS it reads the host's `PATH` and a graph census can count
    # the population instead of guessing at it.
    check decision.passthrough == @["PATH"]

  test "a non-declaring edge keeps the directories the graph DID resolve":
    # Regression guard against "fix D1 by inheriting only". At the base
    # commit a no-ref typed-tool edge got `<its own tool's dir>:<host>`;
    # dropping the prefix would be a new defect wearing the fix's
    # clothes. MEASURED shape this protects: the five
    # `reprobuild.python_test.*` edges, whose prefix is their own
    # `python3` and whose sub-tools (`nim`, `bash`, `git`) are the
    # host's.
    let scratch = createTempDir("repro-toolpath-decide-prefix-", "")
    defer: removeDir(scratch)
    let binDir = fixtureDir(scratch)

    let decision = actionPathDecision(binDir, edgeDeclaresTools = false)
    checkpoint("env: " & $decision.env)
    check decision.class == apcInherited
    check decision.env == @["PATH=" & binDir & $PathSep & getEnv("PATH")]
    check decision.passthrough == @["PATH"]

  test "NO input to actionPathDecision produces an empty PATH value":
    # THE INVARIANT, stated over the whole input space rather than over
    # the two cases above. `PATH=` is not a portability question or a
    # key question: `findExe` inside such an action returns `""`, so a
    # test that probes for its tools skips itself into a green,
    # cacheable pass.
    let scratch = createTempDir("repro-toolpath-decide-never-empty-", "")
    defer: removeDir(scratch)
    let binDir = fixtureDir(scratch)

    for prefix in ["", binDir, binDir & $PathSep & (scratch / "second")]:
      for declares in [false, true]:
        let decision = actionPathDecision(prefix, edgeDeclaresTools = declares)
        checkpoint("prefix=" & prefix & " declares=" & $declares &
          " -> " & $decision.env & " / " & $decision.passthrough)
        for entry in decision.env:
          check entry != "PATH="
          check not entry.startsWith("PATH=" & $PathSep)
        # When no entry is emitted the edge must still declare that it
        # is inheriting, so the omission is not silent either.
        if decision.env.len == 0:
          check decision.passthrough == @["PATH"]

    # And the empty-prefix inherited shape emits nothing rather than the
    # host value, so no host `$PATH` snapshot is written into the
    # lowered graph for the 1372 edges that take it.
    let noPrefix = actionPathDecision("", edgeDeclaresTools = false)
    check noPrefix.env.len == 0
    check noPrefix.passthrough == @["PATH"]

  test "the classifier reads the decision back off a real BuildAction":
    # The census instrument. `classifyActionPath` is what the engine's
    # `EnvironmentInheritanceCensus` and `repro graph --view=env` both
    # call, so what it says about an action is what the build header
    # reports about the graph. It classifies the ARTIFACT, not the
    # lowering's opinion of the artifact — the distinction that matters,
    # because the lowering's opinion was written down and was wrong.
    proc probe(env, passthrough: openArray[string]): ActionPathDeclaration =
      classifyActionPath(action("probe", ["/bin/true"],
        governingLockIdentity = lockIdentityOutsideSolvedGraph(),
        env = env, envPassthrough = passthrough))

    check probe(["PATH=/a/bin"], []) == apdHermetic
    check probe(["PATH=/a/bin"], ["PATH"]) == apdInherited
    check probe([], ["PATH"]) == apdInherited
    check probe([], []) == apdAbsent
    # The defect, named as its own class rather than folded into
    # "declares a variable" — which is how the build header reported
    # 1372 empty-PATH edges as ordinary declaring actions.
    check probe(["PATH="], []) == apdEmpty
    check probe(["PATH="], ["PATH"]) == apdEmpty
    # Last-write-wins, matching `prependPathDirsToArgvEnv`: a later
    # empty entry is the value the child gets.
    check probe(["PATH=/a/bin", "PATH="], []) == apdEmpty

  test "the build header names an empty PATH as a defect, not as a fact":
    # `environmentInheritanceHeaderLine` is the line every `repro build`
    # prints. Before this, it said "all N also inherit the build
    # environment (declared entries overlay it, they do not replace it)"
    # — which is true of the environment as a whole, false of any single
    # variable, and was the sentence the D1 comment cited.
    var census: EnvironmentInheritanceCensus
    census.totalActions = 10
    census.declaringActions = 10
    census.hermeticPathActions = 7
    census.inheritedPathActions = 3
    let clean = environmentInheritanceHeaderLine(census)
    checkpoint(clean)
    check "0 EMPTY" in clean
    check "DEFECT" notin clean
    # The false universal claim must not come back.
    check "they do not replace it" notin clean

    census.hermeticPathActions = 6
    census.emptyPathActions = 1
    let dirty = environmentInheritanceHeaderLine(census)
    checkpoint(dirty)
    check "1 EMPTY" in dirty
    check "DEFECT" in dirty

  test "the hermetic branch is what keeps the shadow unreachable":
    # Ties the emission decision back to the property this branch
    # exists for. The same widened profile that the sub-tool-shadow case
    # above feeds to `actionPathEnvEntry` is fed here to the decision
    # the LOWERING makes, in both directions:
    #
    #   declares a ref  -> hermetic, the shadow directory is absent
    #   declares nothing -> inherited, the shadow directory is present
    #
    # The second row is not a regression being hidden; it is the
    # boundary being stated. An edge that names nothing cannot be given
    # a hermetic PATH without guessing what it runs, and guessing is
    # what turns 504 host-probing test binaries into silent skips.
    let scratch = createTempDir("repro-toolpath-decide-shadow-", "")
    defer: removeDir(scratch)
    let binDir = fixtureDir(scratch)
    let shadowDir = scratch / "shadow-bin"
    writeExecutable(shadowDir, FixtureSubToolName, "echo SHADOWED")

    let widened = resolvePathOnlyTool(fixtureUseDef(),
      pathValue = shadowDir & $PathSep & binDir)
    check widened.resolvedExecutablePath == binDir / FixtureToolName

    let hermetic = actionPathDecision(binDir, edgeDeclaresTools = true)
    check hermetic.env == @["PATH=" & binDir]
    check not hermetic.env[0].contains(shadowDir)

    # Non-vacuity: the shadow directory IS reachable on the other
    # branch, so the assertion above is about the branch and not about
    # a shadow directory that could never have appeared anywhere.
    let savedPath = getEnv("PATH")
    putEnv("PATH", shadowDir & $PathSep & savedPath)
    defer: putEnv("PATH", savedPath)
    let inherited = actionPathDecision(binDir, edgeDeclaresTools = false)
    checkpoint("inherited: " & $inherited.env)
    check inherited.env[0].contains(shadowDir)
    check inherited.passthrough == @["PATH"]
