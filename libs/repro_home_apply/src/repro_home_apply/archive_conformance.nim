## Conformance of one `tarball` arm the HOME ARCHIVE REALIZER owns, decided by
## realizing it.
##
## The sibling of ``repro_tool_profiles/tarball_conformance``, for the other
## half of the split recorded as Provisioning-Contributions.md §"Open gaps" 3:
## an arm that asks for an installer run, an MSYS2 merge, a pre-install step,
## launcher emission, a nested 7z pass, an ``extractPath`` flatten or a digest
## other than SHA-256 is realized by ``builtin_adapter.realizeBuiltinPackage``
## and refused by name by the `uses:` provisioning edge. Ten of this host's
## catalog arms are in that class, so a sweep that only drove the `uses:` edge
## would report them as "not mine" and nothing would check them.
##
## **The rule here is this realizer's own rule, which is weaker.** The `uses:`
## edge probes with ``rejectSymlinks = true`` and refuses a declared path
## reached through a symlink; ``realizeBuiltinPackage`` does not, and arms it
## owns rely on that. ``llvm-mingw`` declares ``bin/clang``, which in the
## pinned llvm-mingw bindist is a symlink to ``clang-22``: under its own
## realizer that arm is correct, and declaring ``bin/clang-22`` instead would
## be a worse declaration that breaks at the next LLVM bump. So conformance is
## judged against the realizer that owns the arm — the issue's requirement is
## to "run the same probe realization uses", and for this realizer that is:
## the declared path, FOLLOWING symlinks, exists inside the realized prefix
## and is executable.
##
## When § Open gaps 3 is closed by moving these arms onto the `uses:` edge,
## the arms that move will have to meet the stricter rule. ``llvm-mingw``'s
## ``bin/clang`` is exactly such an arm, and that is a consequence of unifying
## the realizers rather than a defect in the recipe today.

import std/[os, strutils]

import repro_interface_artifacts
import repro_local_store
from repro_tool_profiles/declared_executable import unsafeRelativePath
from repro_tool_profiles/realization_selection import
  archiveInstallerFeatures

import ./package_catalog
import ./builtin_adapter

type
  ArchiveArmConformanceVerdict* = enum
    ## What realizing one home-realizer arm on this host established.
    aacOk = "ok"
    aacOwnedByUsesEdge = "owned-by-uses-edge"
      ## A plain archive: the `uses:` provisioning edge realizes it, and
      ## ``tarball_conformance`` is its check. Nothing was downloaded.
    aacProjectionFailed = "projection-failed"
      ## ``archiveRealizationOf`` refused the record: an archive format,
      ## install method, pre-install step or digest the realizer cannot read.
      ## A refusal, not a default — so it is a conformance failure.
    aacRealizeFailed = "realize-failed"
    aacDeclaredExecutableMissing = "declared-executable-missing"
    aacDeclaredExecutableNotExecutable = "declared-executable-not-executable"
    aacDeclaredExecutableOutsidePrefix = "declared-executable-outside-prefix"

  ArchiveArmConformance* = object
    packageSelector*: string
    url*: string
    declaredExecutablePath*: string
    archiveType*: string
    os*: string
    cpu*: string
    verdict*: ArchiveArmConformanceVerdict
    detail*: string
    prefix*: string
    resolvedExecutablePath*: string

proc declaredPathIsUsable(prefix, declaredPath: string):
    tuple[ok: bool; resolved, why: string] =
  ## The home archive realizer's rule for a declared path, stated once.
  ##
  ## Symlinks are FOLLOWED (see the module header): the question is whether a
  ## consumer handed this prefix can run what the arm names, and on POSIX the
  ## stable name upstream publishes is routinely a link to a versioned file.
  ## What is still required: the declaration is prefix-relative, something is
  ## there, it resolves inside the prefix, and it is executable.
  if declaredPath.unsafeRelativePath:
    return (ok: false, resolved: "",
      why: "declares an unsafe executable path " & declaredPath)
  let candidate = prefix / declaredPath
  if not fileExists(candidate):
    return (ok: false, resolved: "",
      why: "lacks executable " & declaredPath)
  var real = ""
  try:
    real = expandFilename(candidate)
  except OSError, IOError:
    return (ok: false, resolved: "",
      why: "declares executable " & declaredPath &
        ", which is present but does not resolve")
  if not real.startsWith(expandFilename(prefix)):
    return (ok: false, resolved: real,
      why: "declares executable " & declaredPath &
        ", which resolves outside the realized prefix (" & real & ")")
  when defined(windows):
    # Windows reports execute permission for ordinary files, so the
    # permission half of the rule says nothing there; presence inside the
    # prefix is the whole of it.
    (ok: true, resolved: real, why: "")
  else:
    let perms = getFilePermissions(real)
    if fpUserExec in perms or fpGroupExec in perms or fpOthersExec in perms:
      (ok: true, resolved: real, why: "")
    else:
      (ok: false, resolved: real,
        why: "declares executable " & declaredPath &
          ", which is present but carries no execute permission")

proc conformArchiveArm*(packageSelector: string;
                        arm: InterfaceTarballProvisioning;
                        storeDir: string): ArchiveArmConformance =
  ## Realize exactly ``arm`` through the home archive realizer into
  ## ``storeDir`` and check every path it declares.
  ##
  ## ``detail.extraExecutables`` are checked too, not only the primary: they
  ## are the other exported executables of the same interface, and
  ## §"Conformance And Trust" asks for a realization binding for EVERY
  ## exported executable. ``jdk`` declares four and the Linux ``ghc`` seven.
  result = ArchiveArmConformance(packageSelector: packageSelector,
    url: arm.url, declaredExecutablePath: arm.executablePath,
    archiveType: arm.archiveType, os: arm.os, cpu: arm.cpu)

  if archiveInstallerFeatures(arm).len == 0:
    result.verdict = aacOwnedByUsesEdge
    return

  var resolution: ArchiveRealization
  try:
    resolution = archiveRealizationOf(packageSelector, arm)
  except CatchableError as err:
    result.verdict = aacProjectionFailed
    result.detail = err.msg.splitLines()[0]
    return

  var realized: RealizeBuiltinResult
  try:
    createDir(storeDir)
    var store = openStore(storeDir)
    realized = realizeBuiltinPackage(store, resolution)
  except CatchableError as err:
    result.verdict = aacRealizeFailed
    result.detail = err.msg.splitLines()[0]
    return

  result.prefix = realized.prefixAbsolutePath
  result.resolvedExecutablePath = realized.resolvedExecutablePath

  var declared = resolution.binRelpath
  if declared.len == 0:
    declared = @[arm.executablePath]
  for path in declared:
    if path.len == 0: continue
    let check = declaredPathIsUsable(result.prefix, path)
    if not check.ok:
      result.verdict =
        if check.why.startsWith("lacks") or
            check.why.startsWith("declares an unsafe"):
          aacDeclaredExecutableMissing
        elif check.why.contains("outside the realized prefix"):
          aacDeclaredExecutableOutsidePrefix
        else:
          aacDeclaredExecutableNotExecutable
      result.detail = "realized prefix " & check.why
      return

  result.verdict = aacOk
  result.detail = ""
