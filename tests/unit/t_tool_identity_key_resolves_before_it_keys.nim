## The tool-identity memo must be keyed on WHAT ``$PATH`` RESOLVES,
## not on the ``$PATH`` string.
##
## ## The defect this pins
##
## ``profileFingerprintFor`` stopped hashing the verbatim host ``$PATH``
## (see ``t_tool_profile_keys_on_resolution_not_search_path.nim``), but
## one layer above it ``toolIdentityCacheKey`` still did:
##
##     if mode == tpmPathOnly:
##       payload.addCacheField(getEnv("PATH"))
##
## That is the key of the on-disk tool-identity memo — the thing that
## decides whether a build re-runs the whole resolver or reuses
## ``path-only-tool-identities.rbtp``. Keyed on the raw string, ANY
## ``$PATH`` difference threw the memo away: a reordered entry, a
## directory that does not exist, one shell exporting the same entries in
## another order, a second terminal, a CI runner. And since the resolved
## executable's blake3 digest landed, the cold path that a ``$PATH``
## change forces is now the expensive one — it re-reads and digests every
## resolved tool binary.
##
## So the claim "the action cache is no longer a function of the caller's
## shell" was only half paid for. This file pays the other half and pins
## both directions of it.
##
## ## Why the field could not simply be deleted
##
## It was carrying a real invalidation, and the comment on
## ``toolIdentityRealizationsUsable`` said so. That predicate is the only
## other freshness check on the memo, and all it asks is whether the
## paths the identity already recorded still EXIST. Prepending a
## directory that shadows ``gcc`` does not make ``/usr/bin/gcc``
## disappear, so the predicate still passes and the memo is still reused
## — pointing at the binary that is no longer the one ``$PATH`` selects.
## Delete the field and that is a silent stale-serve.
##
## The fix keys on the RESOLUTION instead, one layer up from where the
## profile fingerprint does the same thing:
## ``pathModeResolutionSignature`` re-runs the resolver's LOOKUP — the
## sidecar probe and ``findExecutableOnPath``, in ``resolvePathOnlyTool``'s
## own order — for each declared use, and folds the answers. Stat calls,
## not digests.
##
## ## Both directions, because neither alone is evidence
##
##   1. A ``$PATH`` difference that changes NO resolution must NOT move
##      the key. (Fails if the raw ``$PATH`` field comes back.)
##   2. A ``$PATH`` difference that changes SOME resolution MUST move it.
##      (Fails if the field is merely deleted, or if the signature stops
##      consulting ``$PATH`` at all.)
##
## Test (2) is the mutation guard on test (1) and vice versa. The suite
## also asserts the key is not simply constant, and that a non-path mode
## folds no ``$PATH`` at all in either direction.
##
## ## No mocks
##
## Real directories and real executable files on the real filesystem,
## driven through the real ``toolIdentityCacheKey`` — the exact proc the
## build calls — with ``$PATH`` supplied as a parameter so the assertions
## do not depend on mutating the test process's environment.

import std/[os, unittest, tempfiles]

import repro_cli_support
import repro_interface_artifacts
import repro_tool_profiles

const ToolName = "identitykey-fixture-tool"
const OtherToolName = "identitykey-fixture-other"

proc writeExecutable(binDir, name, body: string) =
  createDir(binDir)
  let toolPath = binDir / name
  writeFile(toolPath, "#!/bin/sh\n" & body & "\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc artifactFor(names: varargs[string]): ProjectInterfaceArtifact =
  var uses: seq[InterfaceToolUse] = @[]
  for name in names:
    uses.add(InterfaceToolUse(
      rawConstraint: name,
      packageSelector: name,
      executableName: name))
  ProjectInterfaceArtifact(
    projectInterface: ProjectInterface(
      projectName: "identitykey-fixture-project",
      packageName: "identitykey-fixture-package",
      toolUses: uses))

suite "tool_identity_key_resolves_before_it_keys":
  test "a PATH entry that changes no resolution does not move the memo key":
    let scratch = createTempDir("repro-identitykey-widen-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")

    let artifact = artifactFor(ToolName)
    let baseline = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir)

    # Appended, LAST, and does not exist: no tool can resolve differently.
    let absentDir = scratch / "no-such-directory"
    check not dirExists(absentDir)
    let widened = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir & $PathSep & absentDir)

    # Precondition — the PATH string really did change. Without this the
    # assertion below could pass on identical inputs.
    check binDir & $PathSep & absentDir != binDir
    # And the resolver really does still answer the same thing.
    check resolvePathOnlyTool(artifact.projectInterface.toolUses[0],
        pathValue = binDir & $PathSep & absentDir).resolvedExecutablePath ==
      binDir / ToolName

    check widened == baseline

  test "a changed LEADING PATH entry that resolves the same tool does not move the memo key":
    # The harder shape: the changed entry is FIRST and it EXISTS — it just
    # holds no matching executable. A key that folded "the first entry"
    # rather than the resolution would pass the previous case and fail
    # this one.
    let scratch = createTempDir("repro-identitykey-leading-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let emptyDir = scratch / "real-but-empty"
    createDir(emptyDir)
    check dirExists(emptyDir)

    let artifact = artifactFor(ToolName)
    let baseline = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir)
    let prefixed = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = emptyDir & $PathSep & binDir)

    check resolvePathOnlyTool(artifact.projectInterface.toolUses[0],
        pathValue = emptyDir & $PathSep & binDir).resolvedExecutablePath ==
      binDir / ToolName
    check prefixed == baseline

  test "a PATH entry holding an unrelated executable does not move the memo key":
    # The shadowing directory contains a REAL executable — one no
    # declared use names. Nothing the project declared resolves
    # differently, so the memo must survive.
    let scratch = createTempDir("repro-identitykey-unrelated-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let noiseDir = scratch / "noise"
    writeExecutable(noiseDir, OtherToolName, "echo NOISE")

    let artifact = artifactFor(ToolName)
    check toolIdentityCacheKey(artifact, tpmPathOnly,
        pathValue = noiseDir & $PathSep & binDir) ==
      toolIdentityCacheKey(artifact, tpmPathOnly, pathValue = binDir)

  test "a PATH entry that SHADOWS a declared tool does move the memo key":
    # The mutation guard on every case above: delete the resolution
    # signature outright and this fails, because nothing else in the memo's
    # freshness story notices. ``toolIdentityRealizationsUsable`` would
    # still pass here — the shadowed binary is still on disk.
    let scratch = createTempDir("repro-identitykey-shadow-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let shadowDir = scratch / "shadow"
    writeExecutable(shadowDir, ToolName, "echo SHADOWED")

    let artifact = artifactFor(ToolName)
    let baseline = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir)
    let shadowed = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = shadowDir & $PathSep & binDir)

    # The resolution really is different, and the shadowed original really
    # does still exist — which is exactly why an existence check cannot
    # substitute for this key.
    check resolvePathOnlyTool(artifact.projectInterface.toolUses[0],
        pathValue = shadowDir & $PathSep & binDir).resolvedExecutablePath ==
      shadowDir / ToolName
    check fileExists(binDir / ToolName)

    check shadowed != baseline

  test "a PATH that no longer resolves a declared tool at all moves the memo key":
    let scratch = createTempDir("repro-identitykey-gone-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let emptyDir = scratch / "empty"
    createDir(emptyDir)

    let artifact = artifactFor(ToolName)
    check toolIdentityCacheKey(artifact, tpmPathOnly, pathValue = emptyDir) !=
      toolIdentityCacheKey(artifact, tpmPathOnly, pathValue = binDir)

  test "a sidecar appearing on PATH moves the memo key":
    # ``resolvePathOnlyTool`` checks for a ``<name>.repro-tool-profile``
    # sidecar BEFORE it looks for an executable, and honours the
    # ``resolvedExecutablePath`` the sidecar names. The signature has to
    # mirror that branch or a generator dropping a sidecar would silently
    # reuse the memo for a different binary.
    let scratch = createTempDir("repro-identitykey-sidecar-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let realDir = scratch / "real"
    writeExecutable(realDir, "actual-binary", "echo REAL")

    let sidecarDir = scratch / "sidecar"
    createDir(sidecarDir)
    writeFile(sidecarDir / (ToolName & ".repro-tool-profile"),
      "reprobuild-tool-profile-v1\n" &
      "resolvedExecutablePath=" & (realDir / "actual-binary") & "\n")

    let artifact = artifactFor(ToolName)
    let baseline = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir)
    let viaSidecar = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = sidecarDir & $PathSep & binDir)

    check resolvePathOnlyTool(artifact.projectInterface.toolUses[0],
        pathValue = sidecarDir & $PathSep & binDir).resolvedExecutablePath ==
      realDir / "actual-binary"
    check viaSidecar != baseline

  test "only the declared uses are consulted, and each of them is":
    # Two declared uses. Shadowing EITHER must move the key — a signature
    # that folded only the first use would pass every case above.
    let scratch = createTempDir("repro-identitykey-two-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    writeExecutable(binDir, OtherToolName, "echo B")

    let artifact = artifactFor(ToolName, OtherToolName)
    let baseline = toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir)

    let shadowFirst = scratch / "shadow-first"
    writeExecutable(shadowFirst, ToolName, "echo SHADOW-A")
    let shadowSecond = scratch / "shadow-second"
    writeExecutable(shadowSecond, OtherToolName, "echo SHADOW-B")

    check toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = shadowFirst & $PathSep & binDir) != baseline
    check toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = shadowSecond & $PathSep & binDir) != baseline

  test "the memo key is not constant":
    # Anti-vacuity: a key that ignored all of its inputs would satisfy
    # every "does not move" assertion in this file.
    let scratch = createTempDir("repro-identitykey-const-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")

    var a = artifactFor(ToolName)
    var b = artifactFor(ToolName)
    b.projectInterface.projectName = "some-other-project"

    check toolIdentityCacheKey(a, tpmPathOnly, pathValue = binDir) !=
      toolIdentityCacheKey(b, tpmPathOnly, pathValue = binDir)
    check toolIdentityCacheKey(a, tpmPathOnly, pathValue = binDir).len > 0

  test "a non-path provisioning mode folds no PATH in either direction":
    # The resolution signature is path-mode only, as the raw field was.
    # Under nix mode neither an irrelevant PATH change nor a SHADOWING one
    # may move the key — the nix adapter does not consult PATH at all.
    let scratch = createTempDir("repro-identitykey-nix-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let shadowDir = scratch / "shadow"
    writeExecutable(shadowDir, ToolName, "echo SHADOWED")

    let artifact = artifactFor(ToolName)
    let baseline = toolIdentityCacheKey(artifact, tpmNix, pathValue = binDir)
    check toolIdentityCacheKey(artifact, tpmNix,
      pathValue = shadowDir & $PathSep & binDir) == baseline
    check toolIdentityCacheKey(artifact, tpmNix, pathValue = "") == baseline

  test "the resolution signature costs a lookup, not a digest":
    # Why the fix is not "hash the resolved executable's bytes into the
    # memo key too": the signature must stay a stat-and-answer probe.
    # An unreadable-but-present executable is still resolvable, and the
    # signature must produce an answer for it without reading it.
    let scratch = createTempDir("repro-identitykey-cost-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    writeExecutable(binDir, ToolName, "echo A")
    let toolPath = binDir / ToolName
    setFilePermissions(toolPath, {fpUserExec})
    defer: setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec})

    let artifact = artifactFor(ToolName)
    let key = toolIdentityCacheKey(artifact, tpmPathOnly, pathValue = binDir)
    check key.len > 0
    check key == toolIdentityCacheKey(artifact, tpmPathOnly,
      pathValue = binDir)
