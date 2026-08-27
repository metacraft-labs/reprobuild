## HM-6 acceptance harness — In-Process-Monitor-Hosting.
##
## Runs ONE arm of ONE round of a REAL parallel build through the real
## build engine and prints a machine-readable record of it. The driver
## (hm6_run.sh) interleaves the arms so machine drift cancels.
##
## WHAT MAKES IT A REAL BUILD RATHER THAN A FIXTURE. The actions are the
## real `gcc -c` invocations that reprobuild's own build issues over its
## own generated C translation units in build/nimcache/repro — the exact
## command line `nim` records in repro.json, over sources ranging from
## 6 KB to 22 MB and costing 0.17 s to 4.4 s of real compiler work each.
## Every action is a real process reading real headers out of the Nim
## runtime, bearssl, blake3, xxh3 and the C library, so the dependency
## evidence is a real evidence set of a few dozen paths rather than one
## marker file. HM-4 and HM-5 both measured `sh -c cat`, whose per-action
## work is ~0 ms; HM-4's own arithmetic says that is the ONE regime where
## hosting must lose, so a null result there proves less than a null
## result here.
##
## WHAT IS STILL SYNTHETIC, stated rather than glossed: the graph is
## constructed here instead of being loaded from repro.nim, because
## `BuildEngineConfig.monitorHosting` has NO CLI or environment
## surface — no construction site outside three test files sets it — so
## `repro build` cannot be asked to host and the two arms cannot be
## compared through the CLI at all. That is itself a finding; see HM-6.
##
## NO MOCKS: real gcc, real files, real shared memory, real monitor.

import std/[os, strutils, times, algorithm, json, sets, osproc]

import repro_build_engine
import repro_core
from repro_test_support import prepareMonitorTools

proc argValue(name: string; default = ""): string =
  for i in 1 .. paramCount():
    let p = paramStr(i)
    if p.startsWith("--" & name & "="):
      return p[(name.len + 3) .. ^1]
  default

proc loadAvg(): string =
  try: readFile("/proc/loadavg").splitWhitespace()[0]
  except CatchableError: "?"

proc livePids(): int =
  for kind, path in walkDir("/proc"):
    if kind == pcDir:
      let n = path.lastPathPart
      if n.len > 0 and n[0] in {'0' .. '9'}:
        inc result

proc realCompileFlags(repoRoot: string): seq[string] =
  ## The flags of the REAL compile command, taken out of the real build's own
  ## record rather than transcribed. `nim` writes every C compile command it
  ## issued into `<nimcache>/repro.json`; this reads the first one and strips
  ## the two parts that are per-translation-unit (`-o <obj>` and the trailing
  ## source), leaving exactly the include paths and defines reprobuild's own
  ## build passes to gcc.
  ##
  ## RAISES rather than guesses if the record is not in the shape it expects
  ## — a harness that silently fell back to a hand-written flag list would be
  ## measuring something other than the build it claims to measure.
  let recordPath = repoRoot / "build" / "nimcache" / "repro" / "repro.json"
  if not fileExists(recordPath):
    raise newException(IOError, "no nim build record at " & recordPath &
      "; run `just build` first — this harness compiles the C translation " &
      "units that build produced")
  let record = parseFile(recordPath)
  if "compile" notin record or record["compile"].kind != JArray or
      record["compile"].len == 0:
    raise newException(ValueError, recordPath &
      " has no non-empty `compile` array; the nim cache record shape changed")
  let entry = record["compile"][0]
  if entry.kind != JArray or entry.len < 2 or entry[1].kind != JString:
    raise newException(ValueError, recordPath &
      " `compile[0]` is not [source, command]; the record shape changed")
  let words = entry[1].getStr().splitWhitespace()
  if words.len < 3 or not words[0].endsWith("gcc"):
    raise newException(ValueError,
      "unexpected compile command in " & recordPath & ": " & entry[1].getStr())
  var i = 1
  var sawOutputFlag = false
  while i < words.len - 1:            # the last word is the source file
    if words[i] == "-o":
      sawOutputFlag = true
      inc i, 2
      continue
    result.add words[i]
    inc i
  if not sawOutputFlag:
    raise newException(ValueError,
      "no `-o` in the recorded compile command; refusing to guess where the " &
      "object file argument was: " & entry[1].getStr())

proc corpus(repoRoot: string; want, stride: int): seq[string] =
  ## A deterministic slice of reprobuild's own generated C sources.
  ## Sorted by name so the slice is identical in both arms and across
  ## rounds; strided so the size mix is the build's own mix rather than
  ## the cheapest or the dearest end of it.
  let dir = repoRoot / "build" / "nimcache" / "repro"
  var all: seq[string] = @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".nim.c"):
      all.add path
  all.sort()
  var i = 0
  while i < all.len and result.len < want:
    result.add all[i]
    i += stride
  if result.len < want:
    quit("corpus too small: wanted " & $want & ", got " & $result.len &
      " from " & dir & " (" & $all.len & " candidates)", 2)

proc evidenceShape(res: ActionResult; subs: seq[(string, string)]): string =
  proc render(name: string; paths: seq[string]): string =
    var items: seq[string] = @[]
    for p in paths:
      var value = p
      for sub in subs:
        value = value.replace(sub[0], sub[1])
      # gcc's own scratch assembly file carries a RANDOM six-character
      # name (`ccXXXXXX.s`), so it differs between two runs of the same
      # command and would make every cross-arm comparison fail for a
      # reason that has nothing to do with hosting. Collapse the name,
      # keep the fact that a scratch file was written.
      if value.startsWith("<tmp>/cc") and
          (value.endsWith(".s") or value.endsWith(".o") or
           value.endsWith(".res")):
        value = "<tmp>/<gcc-scratch>" & value[value.rfind('.') .. ^1]
      items.add value
    items.sort()
    name & "=[" & items.join(" ") & "]"
  let ev = res.evidence
  @[
    render("declaredInputs", ev.declaredInputs),
    render("declaredOutputs", ev.declaredOutputs),
    render("depfileInputs", ev.depfileInputs),
    render("monitorReads", ev.monitorReads),
    render("monitorWrites", ev.monitorWrites),
    render("monitorProbes", ev.monitorProbes),
    render("monitorDirectoryEnumerations", ev.monitorDirectoryEnumerations),
    render("diagnostics", ev.diagnostics)
  ].join("\n")

proc hostCaptureFiles(cacheRoot: string): int =
  ## The runtime witness that the engine hosted io-mon itself: nothing
  ## else in the engine writes `<cacheRoot>/actions/*.host.stdout`.
  let dir = cacheRoot / "actions"
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".host.stdout"):
      inc result

when isMainModule:
  let repoRoot = argValue("repo", getCurrentDir())
  let arm = argValue("arm", "hosted")
  let parallelism = parseInt(argValue("parallelism", "8"))
  let want = parseInt(argValue("actions", "60"))
  let stride = parseInt(argValue("stride", "13"))
  let runRoot = argValue("runroot")
  let outPath = argValue("out")
  if runRoot.len == 0 or outPath.len == 0:
    quit("--runroot and --out are required", 2)
  let ccFlags = realCompileFlags(repoRoot)

  let hosted = arm == "hosted"
  let workRoot = runRoot / "work"
  let cacheRoot = runRoot / "cache"
  createDir(workRoot)

  let tools = prepareMonitorTools(repoRoot, runRoot, "hm6")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)

  # `--work=trivial` is the SENSITIVITY CONTROL, not an alternative
  # measurement. A harness that reports "no difference" on the real build is
  # worth nothing unless it can be shown to report a difference where one is
  # known to exist: HM-4 measured hosting 2-3x SLOWER than the wrapper at
  # parallelism 8 for actions doing ~0 ms of real work. This mode reproduces
  # that action shape — one `open`/`read` of a small marker and nothing else —
  # so the real-build null result can be distinguished from a blind
  # instrument.
  #
  # In this mode two fields of the record below say nothing: `readTheSource`
  # is 0 by construction (a trivial action reads its marker, not a `.nim.c`)
  # and `corpusBytes` describes a corpus the actions never open. They are
  # still emitted rather than nulled, so that a record is the same shape in
  # both modes and a reader comparing two records is not comparing two
  # schemas.
  let trivial = argValue("work", "real") == "trivial"
  let sources = corpus(repoRoot, want, stride)
  var actions: seq[BuildAction] = @[]
  for i, src in sources:
    let obj = "tu-" & align($i, 4, '0') & ".o"
    var argv = @["gcc"]
    if trivial:
      let marker = workRoot / ("marker-" & align($i, 4, '0') & ".txt")
      writeFile(marker, "hm6 marker payload " & $i & "\n")
      argv = @["/bin/sh", "-c", "cat " & quoteShell(marker) & " > " &
        quoteShell(obj)]
    else:
      argv.add ccFlags
      argv.add "-o"
      argv.add obj
      argv.add src
    actions.add action("tu-" & align($i, 4, '0'), argv,
      cwd = workRoot,
      outputs = [obj],
      commandStatsId = "hm6-compile",
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      dependencyPolicy = automaticMonitorGatheringPolicy())

  let config = BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: tools.monitorCliPath,
    monitorCliPath: tools.monitorCliPath,
    monitorCliArgs: tools.monitorCliArgs,
    maxParallelism: uint32(parallelism),
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    bypassRunQuota: true,
    monitorHosting:
      if hosted: mhmWhereSupported else: mhmNever)

  let loadBefore = loadAvg()
  let pidsBefore = livePids()
  let t0 = epochTime()
  let run = runBuild(graph(actions), config)
  let wallMs = (epochTime() - t0) * 1000.0
  let loadAfter = loadAvg()
  let pidsAfter = livePids()

  # Every action monitored, and monitored COMPLETELY. Counted rather
  # than asserted so a shortfall is reported with its reason instead of
  # aborting the round.
  var succeeded = 0
  var withDepfile = 0
  var withReads = 0
  var readTheSource = 0
  var complete = 0
  var failures: seq[string] = @[]
  var shapes = newJObject()
  # Longest pattern first, always. The roots nest — `$TMPDIR` may be inside
  # the run root or the run root inside `$TMPDIR`, depending on how the
  # driver invoked this — so the order cannot be written down by hand
  # without being wrong for one of the two layouts. Sorting by length makes
  # the most specific prefix win either way.
  var subs = @[
    (getTempDir().strip(leading = false, chars = {'/'}), "<tmp>"),
    (workRoot, "<work>"),
    (cacheRoot, "<cache>"),
    (runRoot, "<run>")
  ]
  subs.sort(proc (a, b: (string, string)): int = cmp(b[0].len, a[0].len))
  for res in run.results:
    if res.status == asSucceeded: inc succeeded
    else:
      failures.add res.id & " exit=" & $res.exitCode & " " &
        res.evidence.diagnostics.join(";") & " stderr=" &
        res.stderr[0 .. min(400, res.stderr.high)]
    if res.monitorDepfilePath.len > 0: inc withDepfile
    if res.evidence.monitorReads.len > 0: inc withReads
    var sawSource = false
    for p in res.evidence.monitorReads:
      if p.endsWith(".nim.c"): sawSource = true
    if sawSource: inc readTheSource
    var incomplete = false
    for d in res.evidence.diagnostics:
      if d.contains("monitor depfile read failed") or
         d.contains("requires monitor evidence but no RMDF path is selected") or
         d.contains("incomplete"):
        incomplete = true
    if not incomplete: inc complete
    var perActionSubs = subs
    perActionSubs.insert((res.id & ".o", "<obj>"), 0)
    shapes[res.id] = %evidenceShape(res, perActionSubs)

  # Segment recycling: io-mon creates one shared-memory chain per
  # monitored action in a fresh `repro-fs-snoop-fragments-*` temp dir
  # and `finish`es it, so the count of distinct dirs this process
  # created is the count of chains it created. The driver polls for
  # them; here we report what survived, which should be nothing.
  var leakedFragmentDirs = 0
  let tmp = getTempDir()
  if dirExists(tmp):
    for kind, path in walkDir(tmp):
      if kind == pcDir and path.lastPathPart.startsWith("repro-fs-snoop-fragments"):
        inc leakedFragmentDirs

  let record = %*{
    "arm": arm,
    "work": (if trivial: "trivial" else: "real"),
    "parallelism": parallelism,
    "actions": run.results.len,
    "wallMs": wallMs,
    "msPerAction": wallMs / float(max(1, run.results.len)),
    "succeeded": succeeded,
    "withDepfile": withDepfile,
    "withReads": withReads,
    "readTheSource": readTheSource,
    "completeEvidence": complete,
    "hostCaptureFiles": hostCaptureFiles(cacheRoot),
    "runQuotaBypassed": run.runQuotaBypassed,
    "loadBefore": loadBefore,
    "loadAfter": loadAfter,
    "pidsBefore": pidsBefore,
    "pidsAfter": pidsAfter,
    "leakedFragmentDirs": leakedFragmentDirs,
    "corpusBytes": block:
      var total = 0'i64
      for s in sources: total += getFileSize(s)
      total,
    "ccFlags": ccFlags.join(" "),
    "failures": %failures,
    "shapes": shapes
  }
  writeFile(outPath, pretty(record))
  echo arm, " p=", parallelism, " n=", run.results.len,
    " wall=", formatFloat(wallMs, ffDecimal, 1), "ms",
    " perAction=", formatFloat(wallMs / float(max(1, run.results.len)),
      ffDecimal, 2), "ms",
    " ok=", succeeded, " dep=", withDepfile, " reads=", withReads,
    " src=", readTheSource, " hostCaptures=", hostCaptureFiles(cacheRoot),
    " load=", loadBefore, "->", loadAfter, " pids=", pidsBefore
  if failures.len > 0:
    echo "FAILURES(", failures.len, "): ", failures[0 .. min(2, failures.high)].join(" | ")
