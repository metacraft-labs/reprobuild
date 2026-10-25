## generate_test_groups.nim — Test-Binary-Grouping M1 prototype.
##
## Emits "group modules": Nim modules that each ``import`` up to G test
## sources, so one ``nim c`` compiles the shared library closure once for
## the whole group instead of once per test file. See
## ``reprobuild-specs/spec/Test-Binary-Grouping.md``.
##
## Run from the repo root::
##
##   nim r scripts/generate_test_groups.nim --dir=tests/unit --max=25 \
##     --out=build/test-groups/unit-g25 [--partition=sorted|cdc]
##
## Writes into ``--out``:
##
##   * ``<groupName>.nim`` — one per group; ``import``s its members in sorted
##     order (module initialisation order = import order).
##   * ``manifest.tsv`` — ``group<TAB>member-source`` for every grouped
##     member, then ``single<TAB>source<TAB>reason`` for every source in
##     ``--dir`` that stays a single-file binary.
##
## DETERMINISM. Group membership is a pure function of (a) the sorted list of
## ``TestSpec.source`` rows under ``--dir`` (read from ``repro_tests.nim``,
## the same table ``.#test-builds`` iterates) and (b) each row's compile-option
## key. No timestamps, no host facts; a second run writes identical bytes.
##
## ELIGIBILITY (M1 — only the default option key is grouped):
##
##   * no ``defines``, no ``extraPassC`` / ``extraPassL``, ``targetOs`` is
##     ``soAny``, not ``selfInterposes``;
##   * no per-project config beside the source (``<file>.nim.cfg`` or
##     ``<file>.nims``) — Nim applies it only when that file is the main
##     module, so it is a compile option the TestSpec row does not show;
##   * the source does not mention ``isMainModule`` or ``getAppFilename``
##     (self-spawning workers; spec M3);
##   * the source has no module-level (column 0) process-global side
##     effect: ``setCurrentDir``, ``putEnv``, ``delEnv``, ``addExitProc``,
##     ``quit``, ``setControlCHook``, ``onSignal``;
##   * no earlier eligible member (sorted order) ``{.compile:}``s a C file it
##     also compiles — Nim would link that object twice ("multiple
##     definition"); the first keeps its place, later ones stay single;
##   * it is not named in ``KeptSingle`` below (members the M1 correctness
##     comparison showed cannot share a process, each with its reason).
##
## PARTITION. ``sorted`` (default) cuts the sorted eligible list into
## near-equal consecutive chunks (k = ceil(N/G)). ``cdc`` (content-defined
## chunking) ends a chunk after a file whose name hash is 0 mod ``G`` or when the
## chunk reaches G, so adding or removing a file usually changes only its own
## chunk. ``--simulate`` prints, for both partitions, how many chunks change
## when each eligible file is removed in turn.

import std/[algorithm, os, parseopt, sets, strutils, tables]
import ../repro_tests

type
  Partition = enum pSorted = "sorted", pCdc = "cdc"

const
  SideEffectStarts = ["setCurrentDir", "putEnv", "delEnv", "addExitProc",
    "quit", "setControlCHook", "onSignal"]
  SelfSpawnMarkers = ["isMainModule", "getAppFilename"]
  KeptSingle: seq[tuple[source, reason: string]] = @[]
    ## Members the per-case correctness comparison showed cannot share a
    ## process. Empty: at 6f17957d85 every grouped tests/unit case gave the
    ## same verdict as in its per-file binary (spec, "M1 results").

proc fnv1a(s: string): uint32 =
  ## A fixed hash, independent of the Nim version's ``hash`` seed.
  result = 2166136261'u32
  for c in s:
    result = (result xor uint32(ord(c))) * 16777619'u32

proc compilePragmaTargets(abs: string): seq[string] =
  ## Repo-normalised paths named by ``{.compile: "<path>".}`` in ``abs``.
  for line in readFile(abs).splitLines:
    let at = line.find("{.compile:")
    if at < 0: continue
    let q1 = line.find('"', at)
    if q1 < 0: continue
    let q2 = line.find('"', q1 + 1)
    if q2 < 0: continue
    result.add normalizedPath(abs.parentDir / line[q1 + 1 ..< q2])

proc ineligibleReason(spec: TestSpec; repoRoot: string): string =
  if spec.defines.len > 0: return "defines: " & spec.defines.join(" ")
  if spec.extraPassC.len > 0 or spec.extraPassL.len > 0:
    return "extraPassC/extraPassL"
  if spec.targetOs != soAny: return "targetOs " & $spec.targetOs
  if spec.selfInterposes: return "selfInterposes"
  let abs = repoRoot / spec.source
  for cfg in [abs & ".cfg", abs.changeFileExt("nims")]:
    if fileExists(cfg): return "per-file config " & cfg.relativePath(repoRoot)
  for (src, why) in KeptSingle:
    if src == spec.source: return why
  let text = readFile(abs)
  for m in SelfSpawnMarkers:
    if m in text: return "self-spawn marker " & m
  for line in text.splitLines:
    for s in SideEffectStarts:
      if line.startsWith(s) and (line.len == s.len or
          line[s.len] in {'(', ' ', '.'}):
        return "module-level " & s
  ""

proc partition(files: seq[string]; g: int; how: Partition): seq[seq[string]] =
  if how == pSorted:
    # Balanced consecutive chunks: k = ceil(N/G), sizes differ by at most one,
    # so no group is a small tail that pays the closure for a few files.
    let n = files.len
    if n == 0: return
    let k = (n + g - 1) div g
    var start = 0
    for i in 0 ..< k:
      let size = n div k + (if i < n mod k: 1 else: 0)
      result.add files[start ..< start + size]
      start += size
    return
  var cur: seq[string]
  let modulus = uint32(max(2, g))
  for f in files:
    cur.add f
    let cut = cur.len >= g or
      (how == pCdc and fnv1a(f.extractFilename) mod modulus == 0)
    if cut:
      result.add cur
      cur = @[]
  if cur.len > 0: result.add cur

proc changedChunks(a, b: seq[seq[string]]): int =
  ## Chunks of ``b`` that are not byte-identical to some chunk of ``a``
  ## (i.e. group binaries that would be recompiled).
  var seen = initHashSet[string]()
  for c in a: seen.incl c.join("\n")
  for c in b:
    if c.join("\n") notin seen: inc result

proc sizesOf(chunks: seq[seq[string]]): string =
  var sizes: seq[string]
  for c in chunks: sizes.add $c.len
  sizes.join(",")

proc main() =
  var dir = "tests/unit"
  var g = 25
  var outDir = ""
  var how = pSorted
  var simulate = false
  for kind, key, val in getopt():
    case key
    of "dir": dir = val.strip(chars = {'/'}, leading = false)
    of "max": g = parseInt(val)
    of "out": outDir = val
    of "partition": how = parseEnum[Partition](val)
    of "simulate": simulate = true
    else:
      stderr.writeLine "unknown argument: " & key
      quit 2
  if g < 1: (stderr.writeLine "--max must be >= 1"; quit 2)
  let repoRoot = getCurrentDir()
  var eligible: seq[string]
  var singles: seq[tuple[source, reason: string]]
  for spec in reprobuildTestSpecs:
    if spec.source.parentDir != dir: continue
    let why = ineligibleReason(spec, repoRoot)
    if why.len == 0: eligible.add spec.source
    else: singles.add (spec.source, why)
  eligible.sort()
  # Two members that ``{.compile:}`` the same C file link its object twice
  # (``multiple definition`` at link time). The first in sorted order keeps
  # its place; the others stay single.
  var compiledBy = initTable[string, string]()
  var kept: seq[string]
  for src in eligible:
    var clash = ""
    for c in compilePragmaTargets(repoRoot / src):
      if c in compiledBy:
        clash = "{.compile.} " & c.relativePath(repoRoot) & " also compiled by " & compiledBy[c]
        break
    if clash.len > 0:
      singles.add (src, clash)
    else:
      for c in compilePragmaTargets(repoRoot / src): compiledBy[c] = src
      kept.add src
  eligible = kept
  singles.sort()

  if simulate:
    for p in [pSorted, pCdc]:
      let base = partition(eligible, g, p)
      var total = 0
      var worst = 0
      for i in 0 ..< eligible.len:
        var less = eligible
        less.delete(i)
        let c = changedChunks(base, partition(less, g, p))
        total += c
        worst = max(worst, c)
      echo $p, " G=", g, " chunks=", base.len,
        " sizes=", sizesOf(base),
        " meanChangedOnRemove=", formatFloat(total / eligible.len, ffDecimal, 2),
        " worst=", worst
    return

  if outDir.len == 0: (stderr.writeLine "--out is required"; quit 2)
  createDir(outDir)
  # A previous run with more groups must not leave stale members behind.
  for old in walkFiles(outDir / "tg_*.nim"): removeFile(old)
  let chunks = partition(eligible, g, how)
  let tag = dir.replace("/", "_").replace("-", "_")
  var manifest = ""
  for i, members in chunks:
    let name = "tg_" & tag & "_g" & $g & "_" & $how & "_" &
      align($(i + 1), 3, '0')
    var body = "## GENERATED by scripts/generate_test_groups.nim — do not edit.\n" &
      "## Test-Binary-Grouping M1 group " & name & " (" & $members.len &
      " members).\n"
    for m in members:
      let rel = relativePath(repoRoot / m, absolutePath(outDir)).changeFileExt("")
      body.add "import \"" & rel.replace('\\', '/') & "\"\n"
      manifest.add name & "\t" & m & "\n"
    writeFile(outDir / name & ".nim", body)
  for (s, why) in singles:
    manifest.add "single\t" & s & "\t" & why & "\n"
  writeFile(outDir / "manifest.tsv", manifest)
  echo "groups=", chunks.len, " grouped=", eligible.len, " single=", singles.len


main()
