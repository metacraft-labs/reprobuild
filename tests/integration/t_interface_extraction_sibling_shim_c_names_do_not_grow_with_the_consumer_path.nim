## The C file Nim generates for a sibling-import shim in an interface
## extraction that is NOT recipe-relative has a short name that does not
## depend on where the consumer, or the extraction's temporary directory,
## lies.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real ``build/bin/repro`` binary as a subprocess against
## real recipes in real temporary directories, with real Nim compiles.
##
## The defect (reprobuild-pm issue
## ``2026-11-18-windows-interface-extraction-names-a-sibling-shim-after-the-consumer-scratch-path-and-passes-max-path.md``):
## the v0.2.27 Windows release build failed in the interface extraction of
## ``reprobuild/repro.nim`` with
## ``Error: cannot open '<nimcache>\@p.repro@sbuild@srepro@sprovider-work@stmp@srepro-sibling-shims@sc_<key>@srepro_sib_reprobuild_test_adapters.nim.c'``,
## 264 characters, past Windows' MAX_PATH. A recipe's ``uses:`` of a
## workspace sibling is compiled through a one-line shim (``usesImportCode``).
## An extraction that owns no shim directory (every Windows extraction, a
## POSIX one that is not recipe-relative) wrote it under the temporary
## directory, which reprobuild ``f93b10dc090`` declared inside the consumer's
## own ``.repro/build/...`` scratch. Nim names a module's C file after its
## shortest path relative to the project or a ``--path`` root
## (``mangleModuleName`` in the compiler's ``modulepaths.nim``), and the
## consumer's directory is a ``--path`` root of the extraction, so the name
## carried the whole scratch path.
##
## The fix places that shim beside the extraction's runner, the compile's
## main module, so its C file is named
## ``@mrepro-sibling-shims@s<consumer key>@srepro_sib_<selector>.nim.c``.
##
## POSIX runs the non-recipe-relative path through
## ``REPRO_RECIPE_RELATIVE_COMPILES=0``; on Windows it is the only path. The
## consumer sits under a deep directory, so a name that still followed the
## consumer's location could not satisfy the bound below. The positive
## control is the build itself: the shim's C file must exist, so the check
## cannot pass by finding nothing.

import std/[os, osproc, strtabs, strutils, unittest]

const ProducerName = "shimnameprod"

const ProducerSource = """
import repro_project_dsl

package shimnameprod:
  build:
    discard
"""

const ConsumerSource = """
import repro_project_dsl

package shimnameconsumer:
  uses:
    "shimnameprod"
  build:
    discard
"""

const ShortPrefix = "@mrepro-sibling-shims@s"
  ## The name of a shim beside the runner, up to its consumer key.

const LongestConsumerKey = "c_".len + len($high(uint32)) + "_".len + 30
  ## `usesImportCode`'s consumer key: `c_<FNV-32>_<at most 30 characters>`.

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc shimCFiles(dir: string): seq[string] =
  ## Every generated C file of a ``repro_sib_<producer>`` shim under ``dir``.
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    let name = extractFilename(path)
    if ("repro_sib_" & ProducerName) in name and name.endsWith(".nim.c"):
      result.add(path)

proc shimSources(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    if extractFilename(path) == "repro_sib_" & ProducerName & ".nim":
      result.add(path)

suite "sibling shim C names do not grow with the consumer path":

  test "a deep consumer's shim is named relative to the extraction runner":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      # Never a silent pass: without the real CLI this test says nothing.
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let tempRoot = getTempDir() / ("rb-shimname-" & $getCurrentProcessId())
      let cacheHome = tempRoot / "cache"
      let actionCacheRoot = tempRoot / "ac"
      let tmpDir = tempRoot / "tmp"
      removeDir(tempRoot)
      defer: removeDir(tempRoot)
      for dir in [cacheHome, actionCacheRoot, tmpDir]:
        createDir(dir)
      # About 100 characters of depth above the workspace: a name that still
      # carried the consumer's location would be at least that much longer.
      var ws = tempRoot / "w"
      for i in 0 ..< 6:
        ws = ws / ("deep-directory-level-" & $i)
      ws = ws / "ws"
      createDir(ws / ProducerName)
      writeFile(ws / ProducerName / "repro.nim", ProducerSource)
      createDir(ws / "consumer")
      writeFile(ws / "consumer" / "repro.nim", ConsumerSource)

      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        env[key] = value
      for name in ["TMPDIR", "TMP", "TEMP"]:
        env[name] = tmpDir
      # The extraction's shared nimcache is under the user cache directory
      # (`interfaceExtractionNimcacheRoot`, `getCacheDir`).
      env["XDG_CACHE_HOME"] = cacheHome
      env["LOCALAPPDATA"] = cacheHome
      env["REPRO_RECIPE_RELATIVE_COMPILES"] = "0"
      let res = execCmdEx(quoteShellCommand([
        reproBin, "build",
        "--daemon=off",
        "--tool-provisioning=path",
        "--action-cache-root=" & actionCacheRoot,
        "--progress=quiet",
        "--log=actions",
        ws / "consumer" / "repro.nim"]), env = env)
      if res.exitCode != 0: checkpoint(res.output)
      check res.exitCode == 0

      let nimcacheRoot = cacheHome / "repro-nimcache-interface"
      let cFiles = shimCFiles(nimcacheRoot)
      checkpoint("shim C files: " & $cFiles)
      # The positive control: the consumer's extraction compiled the shim.
      check cFiles.len >= 1
      let bound = ShortPrefix.len + LongestConsumerKey +
        ("@srepro_sib_" & ProducerName & ".nim.c").len
      for path in cFiles:
        let name = extractFilename(path)
        check name.startsWith(ShortPrefix)
        check "deep-directory-level" notin name
        check name.len <= bound
      # The shim source itself sits beside a runner, in the shared nimcache
      # pool, and not in the extraction's declared temporary directory
      # (`extractInterfaceEdge`: `<scratch>/tmp`, the consumer's
      # `.repro/build/repro/provider-work/tmp`), where the defect put it.
      # The PROVIDER compile's own shim, under its private home's `tmp`
      # (`providerCompileLaunchEnv`), is not this edge's and stays there.
      let extractionTmp = ws / "consumer" / ".repro" / "build" / "repro" /
        "provider-work" / "tmp"
      checkpoint("shim sources in the consumer tree: " &
        $shimSources(ws / "consumer"))
      check shimSources(nimcacheRoot).len >= 1
      check shimSources(extractionTmp).len == 0
      check shimSources(tmpDir).len == 0
