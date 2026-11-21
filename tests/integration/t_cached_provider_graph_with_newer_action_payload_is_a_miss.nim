## A CACHED PROVIDER GRAPH WHOSE ACTION PAYLOADS A NEWER `repro` WROTE IS A
## CACHE MISS FOR AN OLDER ONE, NOT THE END OF ITS BUILD.
##
## `provider-fragments.rbsz` (the provider-graph snapshot) carries every
## action of a project as a `gnkAction` node whose payload is the
## `BuildActionPayload` envelope (`RBAP`, u16 version, u32 length). The
## snapshot is served from disk when its `providerArtifactId`, its provider
## binary and its evaluation inputs are unchanged -- none of which names the
## payload version, so a payload version the reading build does not know
## reaches `decodeBuildActionPayload` from a cache hit. Before the fix that
## raised `unsupported build action payload version` and `repro build` exited
## 1 at "loading project interface", naming neither the entry nor either
## version (reprobuild-pm issue 2026-10-20 "A cached build-action payload
## written by a newer `repro` aborts an older one's build instead of
## missing").
##
## The rule this file pins is the one Incremental-Invalidation.md §"Record
## payload schemas" and Action-Cache-Per-Edge-Store.md §"Compatibility" state
## for every record shared between binaries: an older reader treats a newer
## record as ABSENT -- a miss and a recomputation, never a misparse and never
## a fatal error -- and `loadProviderGraphSnapshot` already applies to the
## snapshot's own envelope version (`t_provider_graph_snapshot_version_skew`).
##
##   * THE FALSIFIER: a snapshot whose action payloads carry
##     `BuildActionPayloadVersion + 1`, under the exact key the next build
##     reads, is recomputed: the build succeeds, the entry on disk is
##     rewritten at this build's version, and ONE diagnostic names the entry,
##     the version found and the version supported.
##   * REPORTED ONCE: the build after that serves the rebuilt entry and says
##     nothing.
##   * A NEWER PROVIDER IS REFUSED BY NAME: when the provider itself writes
##     newer payloads -- it was compiled against a reprobuild source tree
##     newer than the engine, which is the only way one can be served,
##     since every provider cache keys on the content of the libraries the
##     provider was compiled against -- no rebuild can help. The build
##     stops with an error naming the provider, both versions and the
##     source tree with the reason it was selected, and leaves no cached
##     graph behind.
##   * THE ARM IS NARROW: a payload that is not a payload at all (a corrupt
##     magic) is not "an entry from another epoch" and still fails the build.
##     Answering corruption with a silent recomputation is how it stays
##     invisible -- the same line `loadProviderGraphSnapshot` draws.
##
## HOW THE NEWER ENTRY IS MADE. The snapshot is written by a real first build
## and decoded with the real `decodeProviderSnapshot`; only the u16 version
## word of each action payload is moved, and the snapshot is re-encoded with
## the real `encodeProviderSnapshot`. Moving the word alone is a faithful
## image of a newer entry for this purpose: what the reader does with it is
## decided by the version check, which precedes every field it reads. Nothing
## else in the snapshot -- the artifact id, the binary evidence, the
## evaluation inputs -- is touched, so the second build reaches it as an
## ordinary cache hit.
##
## MOCK POLICY - none. The real `build/bin/repro` runs every build, with a
## private action-cache and store root so no other session's entries are
## read or written.

import std/[os, osproc, strutils, unittest]

import repro_test_support/process_fixtures

import repro_project_dsl
import repro_provider_runtime

const Recipe = """
import repro_project_dsl

package payloadskew:
  build:
    fs.writeText(actionId = "write-marker", output = "out/marker.txt",
      text = "built\n")
"""

const DiagnosticMarker = "newer build action payload"
  ## The stable part of the one diagnostic a miss of this kind reports.

proc build(reproBin, projectRoot, actionCacheRoot, storeRoot: string):
    tuple[output: string; exitCode: int] =
  let res = execCmdEx(quoteShellCommand([
    "env",
    "REPROBUILD_STORE_ROOT=" & storeRoot,
    "REPRO_STORE_ROOT=" & storeRoot,
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    projectRoot]))
  (output: res.output, exitCode: res.exitCode)

proc snapshotPath(projectRoot: string): string =
  for path in walkDirRec(projectRoot / ".repro"):
    if extractFilename(path) == "provider-fragments.rbsz":
      return path
  ""

proc toByteSeq(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc toText(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc actionPayloadVersions(path: string): seq[uint16] =
  ## The envelope version of every action payload in the snapshot at
  ## ``path``, read at its pinned offset (u16 LE after the 4-byte magic).
  let snapshot = decodeProviderSnapshot(toByteSeq(readFile(path)))
  for fragment in snapshot.fragments:
    for node in fragment.nodes:
      if node.kind == gnkAction and node.payload.len >= 6:
        result.add(uint16(ord(node.payload[4])) or
          (uint16(ord(node.payload[5])) shl 8))

proc rewriteActionPayloads(path: string;
                           rewrite: proc(payload: var string)): int =
  ## Re-encode the snapshot at ``path`` with every action payload passed
  ## through ``rewrite``; everything else is kept byte-for-byte. Returns
  ## how many payloads were rewritten, so a caller can refuse a vacuous run.
  var snapshot = decodeProviderSnapshot(toByteSeq(readFile(path)))
  for fragment in snapshot.fragments.mitems:
    for node in fragment.nodes.mitems:
      if node.kind == gnkAction:
        rewrite(node.payload)
        inc result
  writeFile(path, toText(encodeProviderSnapshot(snapshot)))

proc diagnosticLines(output: string): seq[string] =
  for line in output.splitLines:
    if DiagnosticMarker in line:
      result.add(line)

proc setUpProject(name: string):
    tuple[root, project, actionCache, store: string] =
  ## A private temp tree: the project, its action-cache root and its store
  ## root, so this case shares no cache with any other build on the host.
  ## Released when the process exits rather than by a ``defer`` in the
  ## case: a failed ``require`` quits the process and skips the ``defer``.
  result.root = expandFilename(getTempDir()) /
    ("rb-payloadskew-" & name & "-" & $getCurrentProcessId())
  releaseDirAtProcessExit(result.root)
  removeDir(result.root)
  createDir(result.root)
  result.project = result.root / "project"
  result.actionCache = result.root / "action-cache"
  result.store = result.root / "store"
  createDir(result.project)
  createDir(result.actionCache)
  writeFile(result.project / "repro.nim", Recipe)

proc reproBinary(): string =
  getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt)

suite "a cached provider graph with a NEWER action payload is a miss":

  test "the newer entry is rebuilt, the build succeeds, and it is reported once":
    let reproBin = reproBinary()
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let tree = setUpProject("newer")

      # --- 1. A real build writes the snapshot this case then ages. ------
      let first = build(reproBin, tree.project, tree.actionCache, tree.store)
      if first.exitCode != 0:
        checkpoint(first.output)
      require first.exitCode == 0
      let path = snapshotPath(tree.project)
      checkpoint("snapshot: " & path)
      require path.len > 0
      # THE POSITIVE CONTROL for the rewrite below: the real build wrote
      # this build's own version, so moving it to +1 really makes it newer.
      let written = actionPayloadVersions(path)
      require written.len > 0
      for version in written:
        check version == BuildActionPayloadVersion
      # ...and an untouched rebuild says nothing about payload versions,
      # so the diagnostic asserted on below cannot be one every build prints.
      let control = build(reproBin, tree.project, tree.actionCache,
        tree.store)
      if control.exitCode != 0:
        checkpoint(control.output)
      require control.exitCode == 0
      check diagnosticLines(control.output).len == 0

      # --- 2. The same entry, as a newer `repro` would have written it. --
      let newer = BuildActionPayloadVersion + 1'u16
      let rewritten = rewriteActionPayloads(path,
        proc(payload: var string) =
          payload[4] = char(newer and 0xff'u16)
          payload[5] = char((newer shr 8) and 0xff'u16))
      require rewritten > 0
      for version in actionPayloadVersions(path):
        require version == newer
      removeFile(tree.project / "out" / "marker.txt")

      # --- 3. THE FALSIFIER: the older build misses and rebuilds. --------
      let second = build(reproBin, tree.project, tree.actionCache,
        tree.store)
      checkpoint(second.output)
      check second.exitCode == 0
      check "unsupported build action payload version" notin second.output
      check fileExists(tree.project / "out" / "marker.txt")
      # Rebuilt at this build's version, so no reader trips on it again.
      for version in actionPayloadVersions(snapshotPath(tree.project)):
        check version == BuildActionPayloadVersion
      # ONE diagnostic, naming the entry and both versions.
      let lines = diagnosticLines(second.output)
      check lines.len == 1
      if lines.len == 1:
        check path in lines[0]
        check ("payload version " & $newer) in lines[0]
        check ("reads up to version " & $BuildActionPayloadVersion) in lines[0]

      # --- 4. REPORTED ONCE: the rebuilt entry is served silently. -------
      let third = build(reproBin, tree.project, tree.actionCache, tree.store)
      if third.exitCode != 0:
        checkpoint(third.output)
      check third.exitCode == 0
      check diagnosticLines(third.output).len == 0

  test "a provider BUILT from newer libraries is refused, naming the source tree":
    # THE OTHER WAY a newer payload reaches an older engine, and the one a
    # cache miss cannot cure. A provider writes the payload version of the
    # libraries it was compiled against, and every cache that can hand the
    # engine a provider binary keys on the content of exactly those
    # libraries. So the only route to a newer provider is the engine
    # RESOLVING a source tree newer than itself -- here `$REPROBUILD_LIBS_DIR`
    # naming a copy of this checkout's libs one payload version ahead, the
    # same shape as a checkout that moved on without a rebuild. Recompiling
    # compiles those libraries again, so the build must stop, and say which
    # tree it used and why, instead of `unsupported build action payload
    # version` with nothing named.
    let reproBin = reproBinary()
    let repoLibs = getCurrentDir() / "libs"
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let tree = setUpProject("libskew")
      let sources = tree.root / "reprobuild-sources"
      createDir(sources)
      copyDir(repoLibs, sources / "libs")
      let libsDir = sources / "libs"
      proc buildWithLibs(): tuple[output: string; exitCode: int] =
        let res = execCmdEx(quoteShellCommand([
          "env",
          "REPROBUILD_LIBS_DIR=" & libsDir,
          "REPROBUILD_STORE_ROOT=" & tree.store,
          "REPRO_STORE_ROOT=" & tree.store,
          reproBin, "build",
          "--daemon=off",
          "--tool-provisioning=path",
          "--action-cache-root=" & tree.actionCache,
          "--progress=quiet",
          tree.project]))
        (output: res.output, exitCode: res.exitCode)

      # THE POSITIVE CONTROL: the unmodified copy is a working source tree,
      # so the refusal below is about the version and nothing else.
      let control = buildWithLibs()
      if control.exitCode != 0:
        checkpoint(control.output)
      require control.exitCode == 0

      let codec = libsDir / "repro_project_dsl" / "src" /
        "repro_project_dsl" / "runtime_core.nim"
      let current = "BuildActionPayloadVersion* = " &
        $BuildActionPayloadVersion & "'u16"
      let newer = BuildActionPayloadVersion + 1'u16
      let text = readFile(codec)
      require current in text
      writeFile(codec, text.replace(current,
        "BuildActionPayloadVersion* = " & $newer & "'u16"))

      for attempt in 1 .. 2:
        # Twice: the refusal must not leave a cached graph behind that the
        # next build would report as a rebuildable miss instead.
        let skewed = buildWithLibs()
        checkpoint("attempt " & $attempt & ":\n" & skewed.output)
        check skewed.exitCode != 0
        check ("wrote build action payload version " & $newer) in
          skewed.output
        check ("newer than version " & $BuildActionPayloadVersion) in
          skewed.output
        check sources in skewed.output
        check "REPROBUILD_LIBS_DIR" in skewed.output
        check diagnosticLines(skewed.output).len == 0
        check snapshotPath(tree.project).len == 0

  test "a CORRUPT action payload in the cached graph still fails the build":
    # The narrow half. A wrong magic is not an entry from another epoch; it
    # is a file that is not what it claims to be, and must stay loud.
    let reproBin = reproBinary()
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let tree = setUpProject("corrupt")
      let first = build(reproBin, tree.project, tree.actionCache, tree.store)
      if first.exitCode != 0:
        checkpoint(first.output)
      require first.exitCode == 0
      let path = snapshotPath(tree.project)
      require path.len > 0
      let rewritten = rewriteActionPayloads(path,
        proc(payload: var string) =
          payload[0] = 'X')
      require rewritten > 0
      let second = build(reproBin, tree.project, tree.actionCache,
        tree.store)
      checkpoint(second.output)
      check second.exitCode != 0
      check "unknown build action payload magic" in second.output
      check diagnosticLines(second.output).len == 0
