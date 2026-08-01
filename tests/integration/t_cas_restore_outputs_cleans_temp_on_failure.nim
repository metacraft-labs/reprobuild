## ``LocalCas.restoreOutputs`` must not leak its staged temp file when
## the final unlink+rename leg fails.
##
## ``restoreOutputs`` materializes each declared output by writing
## ``<dest>.reprotmp.<pid>`` first, then unlinking ``<dest>`` and
## renaming the temp file over it. Both of the latter two steps can fail
## for reasons unrelated to cache integrity. Before the fix the raise
## escaped with the temp file still on disk, so each retry cycle left
## another ``<dest>.reprotmp.<pid>`` sibling behind and the output
## directory accumulated them without bound.
##
## APPROXIMATION NOTICE — read before trusting this test's scope.
## The production failure that motivated the fix is a Windows-only
## condition: the platform refuses ``DeleteFile`` on an executable image
## that a running process currently has mapped, so the failure lands on
## the ``removeFile(dest)`` leg. That condition CANNOT be reproduced on
## Linux, and this test does not reproduce it. It exercises the same
## leak through a different, genuinely reachable failure of the same
## shape: the destination path is an existing NON-EMPTY DIRECTORY, so
## ``fileExists(dest)`` is false, ``removeFile`` is skipped, and
## ``rename(2)`` refuses the move. The failure therefore lands one leg
## later than the Windows case. What both share — and what this test
## actually pins — is that control leaves ``restoreOutputs`` between a
## successful ``writeFile(tmp)`` and a successful move, which is exactly
## the window in which the temp file leaks. The cleanup handler under
## test covers both legs; only the second is observable here.
##
## No mocks. The test drives the real ``LocalCas`` and the real
## ``ActionCache`` against a real temp directory on the real
## filesystem, records a real action result, and calls the real
## ``restoreOutputs``. Nothing is stubbed or faked, so no mock
## justification is required.

import std/[os, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store

import repro_test_support

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.restore-temp-leak." & name),
    hdActionFingerprint)

proc leakedTempFiles(dir: string): seq[string] =
  ## Every ``*.reprotmp.*`` staging sibling left in ``dir``.
  result = @[]
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile and path.extractFilename.contains(".reprotmp."):
      result.add(path.extractFilename)

suite "integration_cas_restore_outputs_cleans_temp_on_failure":
  when isNixSupported:

    test "a failed restore removes its staged temp file and re-raises":
      let tempRoot = createTempDir("repro-restore-leak", "")
      defer: removeDir(tempRoot)

      let reproRoot = tempRoot / ".repro"
      let cas = openLocalCas(reproRoot / "cas")
      var cache = openActionCache(reproRoot / "action-cache")

      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      let inputPath = actionRoot / "input.txt"
      writeFile(inputPath, "alpha\n")
      let outputPath = actionRoot / "out.bin"
      writeFile(outputPath, "restored payload\n")

      let weak = weakFor("blocked-move")
      let record = cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out.bin"], actionRoot)
      check record.outputs.len == 1

      # Replace the output file with a NON-EMPTY DIRECTORY at the same
      # path. ``restoreOutputs`` will stage its temp file successfully
      # and then fail the rename, which is the leak window.
      removeFile(outputPath)
      createDir(outputPath)
      writeFile(outputPath / "occupant.txt", "blocks the rename\n")

      check leakedTempFiles(actionRoot).len == 0

      var raised = false
      try:
        cas.restoreOutputs(record, actionRoot)
      except OSError:
        raised = true
      except CatchableError:
        raised = true

      # The failure must still propagate: the caller asked for the
      # declared outputs to be materialized and they were not.
      check raised

      # ...and the staged temp file must NOT survive the failure.
      check leakedTempFiles(actionRoot) == newSeq[string]()

    test "repeated failed restores do not accumulate temp files":
      let tempRoot = createTempDir("repro-restore-leak-repeat", "")
      defer: removeDir(tempRoot)

      let reproRoot = tempRoot / ".repro"
      let cas = openLocalCas(reproRoot / "cas")
      var cache = openActionCache(reproRoot / "action-cache")

      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      let inputPath = actionRoot / "input.txt"
      writeFile(inputPath, "beta\n")
      let outputPath = actionRoot / "out.bin"
      writeFile(outputPath, "payload\n")

      let weak = weakFor("blocked-move-repeat")
      let record = cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out.bin"], actionRoot)

      removeFile(outputPath)
      createDir(outputPath)
      writeFile(outputPath / "occupant.txt", "blocks the rename\n")

      # This is the production signature: one leaked temp file per
      # failing cycle, growing without bound.
      for _ in 0 ..< 8:
        try:
          cas.restoreOutputs(record, actionRoot)
        except CatchableError:
          discard
      check leakedTempFiles(actionRoot) == newSeq[string]()

    test "a successful restore leaves no temp file behind":
      let tempRoot = createTempDir("repro-restore-ok", "")
      defer: removeDir(tempRoot)

      let reproRoot = tempRoot / ".repro"
      let cas = openLocalCas(reproRoot / "cas")
      var cache = openActionCache(reproRoot / "action-cache")

      let actionRoot = tempRoot / "action"
      createDir(actionRoot)
      let inputPath = actionRoot / "input.txt"
      writeFile(inputPath, "gamma\n")
      let outputPath = actionRoot / "out.bin"
      writeFile(outputPath, "restored payload\n")

      let weak = weakFor("clean-move")
      let record = cache.recordActionResult(cas, weak, ffpChecksum,
        [inputPath], ["out.bin"], actionRoot)

      removeFile(outputPath)
      cas.restoreOutputs(record, actionRoot)
      check readFile(outputPath) == "restored payload\n"
      check leakedTempFiles(actionRoot) == newSeq[string]()
