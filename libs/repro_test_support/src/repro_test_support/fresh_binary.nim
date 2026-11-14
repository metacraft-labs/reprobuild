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
## for another binary is refused. The binary is fresh when every listed
## file still exists and none is newer than the binary, checked when the
## test runs. Anything else raises ``StaleHelperBinary``
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
## ``fresh-accepts-user-config`` (a list whose binary was built reading the
## user's Nim configuration is accepted; §13 decision 142).
##
## Mocks: none -- this is test support; it reads the real build outputs.

import std/[algorithm, json, os, sets, strutils, times]

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

const ListingFilters = ["resolution", "every-entry", "resolution-no-subdirs",
                        "resolution-no-project-cfg", "resolution-no-nim-cfg",
                        "resolution-counts-tool-dirs"]
  ## The listing filters a list may name (``listing-filter``). Only
  ## ``resolution`` is written outside a falsifier run of
  ## ``scripts/write_helper_deps.sh``; each other one drops one rule, so
  ## the case that rule holds goes red.
const NeverCounted = [".nimcache", "build", ".git", "result",
                      ".direnv", ".repro", "nimcache", "htmldocs", "test-logs"]
  ## Entries that never change what the compiler resolves: build output,
  ## VCS metadata and a ``nix build`` link (§13 decision 114), and a
  ## checkout's tool directories (decision 115 (B)). Kept in step with
  ## ``never_counted`` in ``scripts/write_helper_deps.sh``.
const NeverCountedBefore115 = [".nimcache", "build", ".git", "result"]
  ## Decision 114's list alone, for the ``resolution-counts-tool-dirs``
  ## filter only a falsifier run writes.

proc decodeListPath(list, encoded, name: string): string =
  ## A path as ``scripts/write_helper_deps.sh`` writes it: every backslash,
  ## control byte and non-ASCII byte as ``\xNN``, so that a name with a
  ## newline stays on its line. Anything else after a backslash is not
  ## something the writer produces, and the list is refused.
  var i = 0
  while i < encoded.len:
    # The writer escapes every space and control byte (round 9): one found
    # raw is not its list, and a name ending in a space must never be
    # checked under the name without it.
    if encoded[i] <= ' ':
      raise newException(StaleHelperBinary, list & " has a path with an " &
        "unescaped space or control byte (" & encoded & "); " &
        helperRebuildHint(name))
    if encoded[i] == '\\':
      if i + 3 < encoded.len and encoded[i + 1] == 'x' and
          encoded[i + 2] in HexDigits and encoded[i + 3] in HexDigits:
        result.add(char(parseHexInt(encoded[i + 2 .. i + 3])))
        i += 4
        continue
      raise newException(StaleHelperBinary, list & " has a path that is " &
        "not escaped the way scripts/write_helper_deps.sh writes one (" &
        encoded & "); " & helperRebuildHint(name))
    result.add(encoded[i])
    inc i

proc readHelperList(repoRoot, name: string):
    tuple[binarySha: string; deps: seq[tuple[kind, path: string]];
          searchPath: seq[string]; listingFilter: string;
          userConfig: string] =
  ## The list ``scripts/write_helper_deps.sh`` wrote for ``name``: the
  ## sha256 of the binary it describes, and every source with its kind
  ## (``module``, ``csource``, ``header``, ``read``). Raises
  ## ``StaleHelperBinary`` when there is no list or it is not one.
  let list = helperBuildDir(repoRoot) / "nimcache" / name / (name & ".deps")
  if not fileExists(list):
    raise newException(StaleHelperBinary, "build/bin/" & name & " has no " &
      "dependency list (" & list & "): nothing shows what it was built " &
      "from; " & helperRebuildHint(name))
  for line in readFile(list).splitLines():
    # Never strip: the writer ends a line at the newline only, and a path
    # keeps every byte of its name (round 9).
    if line.len == 0: continue
    let sp = line.find(' ')
    if sp < 0:
      raise newException(StaleHelperBinary, list & " is not a dependency " &
        "list written by scripts/write_helper_deps.sh; " & helperRebuildHint(name))
    let kind = line[0 ..< sp]
    let value = line[sp + 1 .. ^1]
    if kind == "binary-sha256": result.binarySha = value.toLowerAscii()
    elif kind in ["module", "csource", "header", "read"]:
      result.deps.add((kind, decodeListPath(list, value, name)))
    elif kind == "searchpath":
      result.searchPath.add(decodeListPath(list, value, name))
    elif kind == "listing-filter" and value in ListingFilters:
      result.listingFilter = value
    elif kind == "user-config" and value in ["skipped", "read"]:
      result.userConfig = value
    elif kind in ["listing", "listing-full", "configs", "configs-probed"] and
        value.len > 65 and value[64] == ' ':
      result.deps.add((kind, value[0 ..< 65] &
        decodeListPath(list, value[65 .. ^1], name)))
    else:
      raise newException(StaleHelperBinary, list & " has an unknown entry " &
        "kind '" & kind & "'; " & helperRebuildHint(name))
  if result.binarySha.len == 0:
    raise newException(StaleHelperBinary, list & " names no binary-sha256: " &
      "it is not tied to a build; " & helperRebuildHint(name))

proc relevantEntry(dir, name: string; searchPath: HashSet[string];
                   filter = "resolution"; full = false): bool =
  ## §13 decisions 111, 114 and 115 (``NeverCounted``): an entry counts when it can change what the
  ## compiler resolves -- a ``.nim``, ``.nimble`` or ``.nims`` file, a Nim
  ## configuration file (``nim.cfg``, ``<project>.nim.cfg``), a
  ## ``nimble.paths``, or a subdirectory -- except ``NeverCounted``. Kept
  ## in step with ``relevant`` in ``scripts/write_helper_deps.sh``.
  if filter == "every-entry": return true
  # ``full``: a directory a later component of an import path is looked up
  # in counts the fixed list too (round 12; ``listing-full``).
  if full: discard
  elif filter == "resolution-counts-tool-dirs":
    if name in NeverCountedBefore115: return false
  elif name in NeverCounted: return false
  if name.endsWith(".nim") or name.endsWith(".nimble") or
      name.endsWith(".nims") or name == "nimble.paths":
    return true
  if name == "nim.cfg": return filter != "resolution-no-nim-cfg"
  if name.endsWith(".nim.cfg"): return filter != "resolution-no-project-cfg"
  let full = normalizedPath(dir / name)
  if full in searchPath: return true
  if dirExists(full): return filter != "resolution-no-subdirs"
  false

proc listingDigest*(dir: string; searchPath: openArray[string] = [];
                    filter = "resolution"; full = false): string =
  ## The sha256 of a directory's relevant entry names (``relevantEntry``),
  ## sorted bytewise and joined by newlines -- what
  ## ``scripts/write_helper_deps.sh`` records for a directory the compiler
  ## listed (§13 decisions 80 and 111). A directory that does not exist
  ## lists no names (decision 115 (A): a search directory created later
  ## changes the digest).
  var sp = initHashSet[string]()
  for p in searchPath: sp.incl(normalizedPath(p))
  var names: seq[string]
  for kind, path in walkDir(dir, relative = true):
    if relevantEntry(dir, path, sp, filter, full):
      names.add(path)
  names.sort(system.cmp[string])
  var ctx: sha256
  ctx.init()
  let joined = names.join("\n")
  if joined.len > 0:
    ctx.update(joined.toOpenArrayByte(0, joined.high))
  toLowerAscii($ctx.finish())

proc configsDigest*(dir: string): string =
  ## The sha256 of the names of a directory's Nim configuration files
  ## (``nim.cfg``, ``config.nims``, any other ``.nims``), sorted bytewise
  ## and joined by newlines -- what ``scripts/write_helper_deps.sh``
  ## records in a ``configs`` line for the project's directory and each of
  ## its parents (§13 decision 115 (A)).
  ## Raises ``OSError`` when the directory cannot be listed: a directory
  ## recorded as listed is never digested as empty (round 12).
  var names: seq[string]
  for kind, path in walkDir(dir, relative = true, checkDir = true):
    if path == "nim.cfg" or path == "config.nims" or path.endsWith(".nims"):
      names.add(path)
  names.sort(system.cmp[string])
  var ctx: sha256
  ctx.init()
  let joined = names.join("\n")
  if joined.len > 0:
    ctx.update(joined.toOpenArrayByte(0, joined.high))
  toLowerAscii($ctx.finish())

proc configsProbeDigest*(dir: string): string =
  ## For a directory that could not be listed when the list was written
  ## (``configs-probed``): which of ``config.nims`` and ``nim.cfg`` exist
  ## there, looked up by name as Nim does, sorted and joined by newlines
  ## (round 12).
  var names: seq[string]
  for n in ["config.nims", "nim.cfg"]:
    if fileExists(dir / n) or symlinkExists(dir / n) or dirExists(dir / n):
      names.add(n)
  var ctx: sha256
  ctx.init()
  let joined = names.join("\n")
  if joined.len > 0:
    ctx.update(joined.toOpenArrayByte(0, joined.high))
  toLowerAscii($ctx.finish())

proc helperConfigs*(repoRoot, name: string):
    seq[tuple[dir, digest: string; probed: bool]] =
  ## The project's directory and its parents, each with the digest of its
  ## configuration file names at list time (decision 115 (A)); ``probed``
  ## for one that could not be listed then (round 12).
  for (kind, value) in readHelperList(repoRoot, name).deps:
    if kind in ["configs", "configs-probed"] and value.len > 65:
      result.add((value[65 .. ^1], value[0 ..< 64], kind == "configs-probed"))

proc helperSearchPath*(repoRoot, name: string): seq[string] =
  ## The compiler's search path the list recorded (decision 111).
  readHelperList(repoRoot, name).searchPath

proc helperListings*(repoRoot, name: string):
    seq[tuple[dir, digest: string; full: bool]] =
  ## The directories the compiler listed while building ``name``, each with
  ## the digest of its relevant entries at list time; ``full`` for one a
  ## later component of an import path is looked up in (round 12).
  for (kind, value) in readHelperList(repoRoot, name).deps:
    if kind in ["listing", "listing-full"] and value.len > 65:
      result.add((value[65 .. ^1], value[0 ..< 64], kind == "listing-full"))

proc helperDependencies*(repoRoot, name: string): seq[string] =
  ## Every source ``build/bin/<name>`` was compiled from that can change,
  ## as its dependency list names them: Nim modules and included files, C
  ## files compiled with ``{.compile.}``, the headers they include, and the
  ## other files the compiler read (``staticRead`` targets, what a
  ## ``staticExec`` command read). Raises ``StaleHelperBinary`` when there
  ## is no list.
  let root = absolutePath(repoRoot)
  when FreshMutation == "fresh-skips-included":
    let linked = linkedModules(repoRoot, name)
  for (kind, dep) in readHelperList(repoRoot, name).deps:
    if kind in ["listing", "listing-full", "configs", "configs-probed"]:
      continue                                    # checked by its digest
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
  # The user's Nim configuration can change what the compiler builds, and
  # it is no source of the tree: a guarded helper is built without it
  # (--skipUserCfg; §13 decision 142), and its list says so.
  when FreshMutation != "fresh-accepts-user-config":
    if readHelperList(repoRoot, name).userConfig != "skipped":
      raise newException(StaleHelperBinary, result & " was built without " &
        "--skipUserCfg, so the user's Nim configuration " &
        "($XDG_CONFIG_HOME/nim) could have changed it; " &
        helperRebuildHint(name))
  let built = getLastModificationTime(result)
  # A directory the compiler listed (a staticExec `ls`, a walkDir in a
  # config.nims) must still list the same entries (§13 decision 80).
  when FreshMutation != "fresh-ignores-listings":
    let searchPath = helperSearchPath(repoRoot, name)
    var filter = readHelperList(repoRoot, name).listingFilter
    if filter.len == 0: filter = "resolution"
    for (dir, digest, full) in helperListings(repoRoot, name):
      # A search directory absent at list time is recorded as listing no
      # names (decision 115 (A)); any other listed directory must exist.
      if not dirExists(dir) and digest != listingDigest(dir):
        raise newException(StaleHelperBinary, result & " was built after " &
          "listing " & dir & ", which no longer exists; " & helperRebuildHint(name))
      if listingDigest(dir, searchPath, filter, full) != digest:
        raise newException(StaleHelperBinary, result & " was built from a " &
          "listing of " & dir & " that has changed since; " &
          helperRebuildHint(name))
  # The configuration files in the project's directory and its parents,
  # which Nim reads without listing them (§13 decision 115 (A)).
  for (dir, digest, probed) in helperConfigs(repoRoot, name):
    var now: string
    if probed:
      now = configsProbeDigest(dir)
    else:
      try: now = configsDigest(dir)
      except OSError as e:
        raise newException(StaleHelperBinary, result & " was built when " &
          dir & " could be listed for its Nim configuration files, and it " &
          "cannot be now (" & e.msg & "); " & helperRebuildHint(name))
    if now != digest:
      raise newException(StaleHelperBinary, result & " was built when " &
        dir & " held other Nim configuration files (nim.cfg, " &
        "config.nims, *.nims); " & helperRebuildHint(name))
  for dep in helperDependencies(repoRoot, name):
    if not fileExists(dep):
      raise newException(StaleHelperBinary, result & " was built from " &
        dep & ", which no longer exists; " & helperRebuildHint(name))
    if FreshMutation != "stale-helper-accepted" and
        getLastModificationTime(dep) > built:
      raise newException(StaleHelperBinary, result & " is older than " &
        dep & " (" & $getLastModificationTime(dep) & " > " & $built &
        "); the test would run an old build; " & helperRebuildHint(name))
