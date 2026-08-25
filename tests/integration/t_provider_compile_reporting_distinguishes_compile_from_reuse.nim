## The ``providerCompileAction:`` line must say whether the provider was
## COMPILED in this invocation or merely REUSED.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real ``build/bin/repro`` binary as a subprocess
## against a real recipe in a real temporary directory, with a real Nim
## compile of a real provider binary. The defect under test is a
## reporting defect in how several engine passes over ONE edge are
## summarised, so every pass has to be the production one; a stubbed
## engine could not reproduce the multi-pass shape at all.
##
## The defect, as measured on ``6d8c883be`` (pre-fix):
##
##   run 2 (nothing to do, 4.6 s wall):
##     providerCompileAction: __repro_provider_compile status=asCacheHit \
##       launched=false cache=cdHit wouldLaunch=false
##   run 3 (provider binary deleted, 64 s wall, ~63 s of it a real
##          ``nim c`` of the provider):
##     providerCompileAction: __repro_provider_compile status=asCacheHit \
##       launched=false cache=cdHit wouldLaunch=false
##
## Byte-identical. A reader cannot tell a cold provider compile from a
## no-op, and at least one agent on this campaign drew — and had to have
## refuted — a conclusion from that line that it could not support in
## either direction.
##
## Mechanism: ``__repro_provider_compile`` is consulted by the engine up
## to three times in ONE ``repro build`` invocation. Only the last of
## those consultations is logged (``repro_cli_support``'s
## ``executeBuildTarget``). ``refreshRecipeProviderSnapshot`` runs the
## same edge earlier and logs NOTHING, so by the time the logged pass
## runs, the compile has already happened and that pass is — correctly —
## a no-op. The line was reporting one pass and being read as if it
## reported the invocation.
##
## The property under test is therefore stated as a DIFFERENCE, not as a
## fixed string: the line emitted by an invocation that compiled the
## provider must not equal the line emitted by an invocation that did
## not. Anything that satisfies that is a fix; nothing that does not is.
##
## Out-of-band corroboration: the provider binary's inode + mtime are
## captured around each run, so "was compiled" is a fact about the
## filesystem rather than the CLI's own account of itself.

import std/[math, os, osproc, strutils, times, unittest]

const RecipeSource = """
import repro_project_dsl

package providerreportprobe:
  build:
    discard
"""

const ProviderLinePrefix = "providerCompileAction: __repro_provider_compile"

proc reproBinary(repoRoot: string): string =
  result = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc providerLine(output: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith(ProviderLinePrefix):
      return stripped
  ""

type BinaryStamp = object
  present: bool
  size: BiggestInt
  mtime: times.Time

proc stampOf(path: string): BinaryStamp =
  if not fileExists(path):
    return BinaryStamp(present: false)
  BinaryStamp(present: true, size: getFileSize(path),
    mtime: getLastModificationTime(path))

proc runBuildCli(reproBin, projectRoot, actionCacheRoot: string):
    tuple[output: string; exitCode: int; seconds: float] =
  let started = epochTime()
  let res = execCmdEx(quoteShellCommand([
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    "--log=actions",
    projectRoot]))
  (output: res.output, exitCode: res.exitCode, seconds: epochTime() - started)

suite "provider-compile reporting distinguishes a compile from a reuse":

  test "the logged line differs between a compiled and a reused provider":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      # Never a silent pass: without the real CLI this test says nothing.
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      # A SHORT root on purpose: nothing here depends on path length, but
      # the provider compile's argv is embedded in its action key and a
      # very deep root makes the fixture needlessly fragile.
      let tempRoot = "/tmp/rb-provrep-" & $getCurrentProcessId()
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      createDir(projectRoot)
      writeFile(projectRoot / "repro.nim", RecipeSource)
      let actionCacheRoot = tempRoot / "action-cache"
      createDir(actionCacheRoot)
      let providerBinary =
        projectRoot / ".repro" / "build" / "repro" / "provider" /
          "project-provider"

      # --- run 1: cold. The provider does not exist yet. -----------------
      let coldBefore = stampOf(providerBinary)
      let cold = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if cold.exitCode != 0:
        checkpoint(cold.output)
      check cold.exitCode == 0
      let coldAfter = stampOf(providerBinary)
      let coldLine = providerLine(cold.output)
      checkpoint("cold (" & $round(cold.seconds, 1) & " s): " & coldLine)
      check coldLine.len > 0
      # Corroboration: the binary really was produced by this run.
      check not coldBefore.present
      check coldAfter.present

      # --- run 2: warm. Nothing to do at all. ----------------------------
      let warm = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if warm.exitCode != 0:
        checkpoint(warm.output)
      check warm.exitCode == 0
      let warmAfter = stampOf(providerBinary)
      let warmLine = providerLine(warm.output)
      checkpoint("warm (" & $round(warm.seconds, 1) & " s): " & warmLine)
      check warmLine.len > 0
      # Corroboration: the binary was NOT touched.
      check warmAfter.present
      check warmAfter.mtime == coldAfter.mtime
      check warmAfter.size == coldAfter.size

      # --- run 3: the provider binary is deleted, so it must be
      #            re-produced. Everything else is unchanged. -------------
      removeFile(providerBinary)
      let rebuilt = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if rebuilt.exitCode != 0:
        checkpoint(rebuilt.output)
      check rebuilt.exitCode == 0
      let rebuiltAfter = stampOf(providerBinary)
      let rebuiltLine = providerLine(rebuilt.output)
      checkpoint("rebuilt (" & $round(rebuilt.seconds, 1) & " s): " &
        rebuiltLine)
      check rebuiltLine.len > 0
      # Corroboration: the binary really was re-produced by this run.
      check rebuiltAfter.present
      check rebuiltAfter.mtime != warmAfter.mtime

      # THE PROPERTY. Run 3 produced the provider binary; run 2 did not.
      # A line that reads identically for both cannot be used to tell
      # them apart, which is the whole reason it is printed.
      check rebuiltLine != warmLine

      # ... and the cold case must not read like the no-op case either.
      check coldLine != warmLine
