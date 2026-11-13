## A helper binary a test runs from ``build/bin`` must be built from the
## tree under test.
##
## A test that spawns ``build/bin/<name>`` (the Evidence sink, the binary
## cache) runs whatever binary is there. When nothing rebuilt it since its
## sources changed, the test reports on an old build, and a red case reads
## green: the A11 round-4 review found the sink's redaction case green only
## because ``build/bin/repro-evidence-sink`` predated the change that broke
## it (reprobuild-pm issue 2026-11-07-addon-allow-listed-source-field-turns-
## the-sinks-redaction-case-red-masked-by-a-stale-sink).
##
## ``freshRepoBinary`` refuses such a binary. Its sources are the list
## ``scripts/write_helper_deps.sh`` writes into
## ``build/nimcache/<name>/<name>.deps`` -- run by ``scripts/build_apps.sh``,
## by the ``repro build .#apps`` edges of the guarded helpers and by the Nim
## 2.2.4 lane (§13 decision 65 of the ReproOS Add-On Mode spec, and its
## round-6 amendment). The list names the sha256 of the binary it
## describes, every Nim module and included file (Nim's ``--genDeps``), the
## C files compiled with ``{.compile.}``, the headers they include, and the
## other files the compiler read (``staticRead`` targets, what a
## ``staticExec`` command read; seen through ``strace``). A list written
## for another binary is refused. Each listed file carries the sha256 of
## its bytes when the list was written; the binary is fresh when every
## listed file still exists with those bytes, checked when the test runs.
## Content, not modification time: CI moves the shared sibling checkouts to
## another consumer's revisions and back between the build and the tests,
## which rewrites files with their old bytes and a new timestamp, and an
## edit that keeps an old timestamp is still an edit. A list written before
## the digests (no ``sha256:``) is checked by modification time, as it was.
## Anything else raises ``StaleHelperBinary``
## naming the first offending file and the command that rebuilds it: the
## test fails, it never silently runs an old build.
##
## Falsifying builds (``-d:reproAddonMutation=...``), each turning its case
## of ``t_fresh_helper_binary_refuses_a_stale_build`` red:
## ``stale-helper-accepted`` (a binary older than its sources is accepted),
## ``fresh-skips-included`` (an included file is not checked),
## ``fresh-skips-outside-tree`` (a module from outside the tree is not
## checked), ``fresh-skips-c-sources``, ``fresh-skips-headers``,
## ``fresh-skips-static-reads`` (that kind of entry is not checked),
## ``fresh-ignores-list-binary`` (a list from another build is accepted),
## ``fresh-trusts-mtime`` (a source's bytes are not compared: an edit that
## keeps an old timestamp is accepted).
##
## Mocks: none -- this is test support; it reads the real build outputs.

import std/[json, os, strutils, times]

import nimcrypto/sha2

const FreshMutation {.strdefine: "reproAddonMutation".} = ""
  ## A falsifying build's name (``repro_addon/mutations``); "" otherwise.

type
  StaleHelperBinary* = object of CatchableError
    ## ``build/bin/<name>`` is missing, has no dependency list, or is older
    ## than a source it was compiled from.

proc helperRebuildHint(name: string): string =
  "rebuild it from this tree first (`just build`, or " &
    "`bash scripts/build_apps.sh`)"

proc helperBuildDir*(repoRoot: string): string =
  ## Where the helper binaries are: ``build/`` of the tree, or
  ## ``$REPRO_TEST_BUILD_DIR`` (the Nim 2.2.4 lane builds its own there,
  ## ``scripts/run_nim224_lane.sh``).
  let d = getEnv("REPRO_TEST_BUILD_DIR")
  if d.len > 0: absolutePath(d, repoRoot) else: repoRoot / "build"

proc linkedModules(repoRoot, name: string): seq[string] =
  ## The tree's modules that have an object in Nim's build record
  ## (``<name>.json``'s ``link``): what the round-4 guard checked. Used only
  ## by the ``fresh-skips-included`` falsifier, to drop what it misses.
  let record = helperBuildDir(repoRoot) / "nimcache" / name / (name & ".json")
  if not fileExists(record): return
  var roots: seq[string]
  for kind, d in walkDir(repoRoot / "libs"):
    if kind in {pcDir, pcLinkToDir} and dirExists(d / "src"): roots.add(d / "src")
  for kind, d in walkDir(repoRoot / "apps"):
    if kind in {pcDir, pcLinkToDir}: roots.add(d)
  roots.add(repoRoot)
  for o in parseJson(readFile(record)){"link"}.getElems():
    var m = extractFilename(o.getStr())
    if not m.endsWith(".nim.c.o"): continue
    m = m[2 ..< m.len - 4].replace("@s", "/")
    for r in roots:
      if fileExists(r / m):
        result.add(r / m)
        break

proc fileSha256(path: string): string =
  ## Hex SHA-256 of the file at ``path``, read in chunks.
  var ctx: sha256
  ctx.init()
  var f = open(path, fmRead)
  defer: f.close()
  var buf = newSeq[byte](1 shl 20)
  while true:
    let n = f.readBytes(buf, 0, buf.len)
    if n <= 0: break
    ctx.update(buf.toOpenArray(0, n - 1))
  toLowerAscii($ctx.finish())

proc splitDigest(value: string): tuple[path, digest: string] =
  ## ``<path> sha256:<64 hex>`` -> (path, hex); a value without the suffix
  ## (a list written before the digests) -> (value, "").
  const Tag = " sha256:"
  let at = value.rfind(Tag)
  if at > 0 and value.len - (at + Tag.len) == 64:
    let hex = value[at + Tag.len .. ^1].toLowerAscii()
    if hex.allCharsInSet(HexDigits):
      return (value[0 ..< at], hex)
  (value, "")

proc readHelperList(repoRoot, name: string):
    tuple[binarySha: string; deps: seq[tuple[kind, path, digest: string]]] =
  ## The list ``scripts/write_helper_deps.sh`` wrote for ``name``: the
  ## sha256 of the binary it describes, and every source with its kind
  ## (``module``, ``csource``, ``header``, ``read``). Raises
  ## ``StaleHelperBinary`` when there is no list or it is not one.
  let list = helperBuildDir(repoRoot) / "nimcache" / name / (name & ".deps")
  if not fileExists(list):
    raise newException(StaleHelperBinary, "build/bin/" & name & " has no " &
      "dependency list (" & list & "): nothing shows what it was built " &
      "from; " & helperRebuildHint(name))
  for raw in readFile(list).splitLines():
    let line = raw.strip()
    if line.len == 0: continue
    let sp = line.find(' ')
    if sp < 0:
      raise newException(StaleHelperBinary, list & " is not a dependency " &
        "list written by scripts/write_helper_deps.sh; " & helperRebuildHint(name))
    let kind = line[0 ..< sp]
    let value = line[sp + 1 .. ^1]
    if kind == "binary-sha256": result.binarySha = value.toLowerAscii()
    elif kind in ["module", "csource", "header", "read"]:
      let (path, digest) = splitDigest(value)
      result.deps.add((kind, path, digest))
    else:
      raise newException(StaleHelperBinary, list & " has an unknown entry " &
        "kind '" & kind & "'; " & helperRebuildHint(name))
  if result.binarySha.len == 0:
    raise newException(StaleHelperBinary, list & " names no binary-sha256: " &
      "it is not tied to a build; " & helperRebuildHint(name))

proc helperDependencyEntries(repoRoot, name: string):
    seq[tuple[path, digest: string]] =
  ## ``helperDependencies`` with the sha256 each source had when the list
  ## was written ("" for a list written before the digests).
  let root = absolutePath(repoRoot)
  when FreshMutation == "fresh-skips-included":
    let linked = linkedModules(repoRoot, name)
  for (kind, dep, digest) in readHelperList(repoRoot, name).deps:
    when FreshMutation == "fresh-skips-outside-tree":
      if not dep.startsWith(root & "/"): continue
    when FreshMutation == "fresh-skips-included":
      if kind == "module" and dep.startsWith(root & "/") and dep notin linked:
        continue
    when FreshMutation == "fresh-skips-c-sources":
      if kind == "csource": continue
    when FreshMutation == "fresh-skips-headers":
      if kind == "header": continue
    when FreshMutation == "fresh-skips-static-reads":
      if kind == "read": continue
    result.add((dep, digest))

proc helperDependencies*(repoRoot, name: string): seq[string] =
  ## Every source ``build/bin/<name>`` was compiled from that can change,
  ## as its dependency list names them: Nim modules and included files, C
  ## files compiled with ``{.compile.}``, the headers they include, and the
  ## other files the compiler read (``staticRead`` targets, what a
  ## ``staticExec`` command read). Raises ``StaleHelperBinary`` when there
  ## is no list.
  for (dep, _) in helperDependencyEntries(repoRoot, name):
    result.add(dep)

proc freshRepoBinary*(repoRoot, name: string): string =
  ## ``<build>/bin/<name>`` when it is at least as new as every source it
  ## was compiled from; raises ``StaleHelperBinary`` otherwise.
  result = helperBuildDir(repoRoot) / "bin" / addFileExt(name, ExeExt)
  if not fileExists(result):
    raise newException(StaleHelperBinary, result & " does not exist; " &
      helperRebuildHint(name))
  # The list must describe THIS binary: a binary built by a path that did
  # not write its list (a hand ``nim c``), or whose list write failed after
  # an earlier one succeeded, is checked against nothing it was built from.
  when FreshMutation != "fresh-ignores-list-binary":
    let want = readHelperList(repoRoot, name).binarySha
    let have = fileSha256(result)
    if want != have:
      raise newException(StaleHelperBinary, result & " is not the binary " &
        "its dependency list describes (list: sha256 " & want & ", binary: " &
        have & "): it was built by a path that wrote no list, or its list " &
        "is from another build; " & helperRebuildHint(name))
  let built = getLastModificationTime(result)
  for (dep, digest) in helperDependencyEntries(repoRoot, name):
    if not fileExists(dep):
      raise newException(StaleHelperBinary, result & " was built from " &
        dep & ", which no longer exists; " & helperRebuildHint(name))
    when FreshMutation == "stale-helper-accepted":
      continue
    if digest.len > 0 and FreshMutation != "fresh-trusts-mtime":
      let now = fileSha256(dep)
      if now != digest:
        raise newException(StaleHelperBinary, result & " was built from " &
          "a different " & dep & " (sha256 then " & digest & ", now " & now &
          "); the test would run an old build; " & helperRebuildHint(name))
    elif getLastModificationTime(dep) > built:
      raise newException(StaleHelperBinary, result & " is older than " &
        dep & " (" & $getLastModificationTime(dep) & " > " & $built &
        "); the test would run an old build; " & helperRebuildHint(name))
