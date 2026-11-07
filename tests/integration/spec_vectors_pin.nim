## Shared by every test that reads the ``test-certificates-spec`` conformance
## suite: the suite at ONE pinned revision, extracted from the sibling's object
## store.
##
## The suite is read at the revision pinned in
## ``content_id/test-certificates-spec-content-vectors.pin`` (the file name
## predates the walker reading every group; ``scripts/check_workflows.sh``
## holds ``.github/sibling-repos`` to the same revision, so CI's clone carries
## it). It is extracted with ``git archive`` from the object store of the
## workspace's ``test-certificates-spec`` sibling, or of
## ``$TEST_CERTIFICATES_SPEC``, never read from its checkout: a checkout moves,
## and a pin moves only in the change that teaches this implementation what
## the new revision says. A missing sibling, or one whose object store lacks
## the pinned revision, is an ERROR naming what to fetch — the caller fails on
## it. A conformance test that quietly stops running has stopped testing
## anything.

import std/[os, osproc, streams, strutils]

proc testCertificatesSpecPinFile*(): string =
  currentSourcePath().parentDir / "content_id" /
    "test-certificates-spec-content-vectors.pin"

proc testCertificatesSpecSibling*(): string =
  let explicit = getEnv("TEST_CERTIFICATES_SPEC")
  if explicit.len > 0: explicit
  else: currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "test-certificates-spec"

proc runSpecGit(dir: string; args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  ## The real git, with an argv (no shell), streams kept apart.
  var process = startProcess("git", workingDir = dir, args = args,
                             options = {poUsePath})
  try:
    process.inputStream.close()
    result.stdout = process.outputStream.readAll()
    result.stderr = process.errorStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc extractPinnedVectors*(scratch: string):
    tuple[root, pin, sibling, error: string] =
  ## ``vectors/`` at the pinned revision, unpacked into ``scratch``. ``root``
  ## is the unpacked ``vectors`` directory; ``error`` is non-empty, naming the
  ## remedy, when the suite cannot be had.
  result.sibling = testCertificatesSpecSibling()
  result.pin = readFile(testCertificatesSpecPinFile()).strip()
  if result.pin.len != 40 or not result.pin.allCharsInSet(HexDigits):
    result.error = "the pin file " & testCertificatesSpecPinFile() &
      " must hold one full commit id"
    return
  if not dirExists(result.sibling):
    result.error = "the test-certificates-spec sibling is absent: expected " &
      "a clone at " & result.sibling & " (or set TEST_CERTIFICATES_SPEC). " &
      "This test needs revision " & result.pin & " of it"
    return
  let probe = runSpecGit(result.sibling,
    ["cat-file", "-e", result.pin & "^{commit}"])
  if probe.code != 0:
    result.error = "revision " & result.pin & " is not in the object store " &
      "of " & result.sibling & "; run `git -C " & result.sibling &
      " fetch` (an unshallow fetch if the clone is shallow)"
    return
  let archive = scratch / "vectors.tar"
  let archived = runSpecGit(result.sibling, ["archive", "--format=tar", "-o",
    archive, result.pin, "vectors"])
  if archived.code != 0:
    result.error = "`git archive " & result.pin & " vectors` failed: " &
      archived.stderr
    return
  let unpacked = execCmdEx("tar -x -f " & quoteShell(archive) & " -C " &
                           quoteShell(scratch))
  if unpacked.exitCode != 0:
    result.error = "could not unpack the vectors archive: " & unpacked.output
    return
  removeFile(archive)
  result.root = scratch / "vectors"
