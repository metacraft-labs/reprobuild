## Every Nim compile in this checkout keeps its nimcache INSIDE the checkout.
##
## WHY.  Nim's default nimcache (`~/.cache/nim/<project>_d`, `_r` for
## -d:release, `%USERPROFILE%\nimcache\<project>_d` on Windows) is keyed by the
## project NAME only, and the generated file names inside it are the same in
## every checkout.  Two checkouts of this repository building the same project
## at the same time therefore share one set of intermediate files, and a build
## can exit 0 with the other checkout's code linked in.  The repo-root
## `config.nims` moves every such cache to
## `<checkout>/.nimcache/<main module's dir>/<module name>_<d|r|check>`; its
## header has the details.
##
## WHAT THIS CHECKS.
##   1. SELF.  The nimcache this test binary was itself compiled with, baked in
##      at compile time by `querySetting(nimcacheDir)`, is inside the checkout.
##      So a test runner that bypasses the config fails here, not only a
##      config that is wrong.
##   2. LAYOUT.  `nim dump` reports exactly the documented directory for this
##      file (from the repo root and from its own directory) and for the main
##      modules below, in debug (`_d`) and with -d:release (`_r`); and an
##      explicit `--nimcache:` on the command line still wins.
##   3. CONTROL.  The same probe with `--skipParentCfg`, which switches the
##      repo-root config off, must resolve OUTSIDE the checkout.  If it does
##      not, the probe cannot tell a shared cache from a local one, every
##      verdict above is vacuous, and the run fails saying so.
##
## Cost: a handful of `nim dump` probes (config evaluation only, no compile),
## about a second in total.
##
## NO MOCKS: the real compiler, the real config files, the real checkout.
##
## The three checks are unittest cases, so this binary speaks the case
## protocol (`--list`, `--list-json`, one case per process) like every other
## test in the suite. It used to be a plain script that ran every probe at
## module scope: it answered `--list` by running the whole check and printing
## no case list, so the inventory could only quarantine it and count nothing.
## Each case resets the failure tally and requires it to be zero at the end,
## so a probe that fails is reported with its message and fails its case.

import std/[compilesettings, json, os, osproc, streams, strtabs, strutils,
  unittest]

const
  SelfNimcache = querySetting(nimcacheDir)
  SelfSource = currentSourcePath()
  CompilerAtBuild = getCurrentCompilerExe()

  # --- Per-repository settings ----------------------------------------------
  RootMarker = "reprobuild.nimble"
    ## A file every checkout of this repository has, used to validate the
    ## derived checkout root.  Never `config.nims`: that is the thing under
    ## test.
  LevelsBelowRoot = 2
    ## How many directories this file sits below the checkout root.
  MainModules: seq[string] = @["apps/repro/repro.nim"]
    ## Checkout-relative main modules probed in debug and release.

var failures = 0

proc refuse(msg: string) =
  inc failures
  echo "  FAIL  ", msg
  checkpoint(msg)

proc pass(msg: string) =
  echo "  ok    ", msg

proc comparable(p: string): string =
  ## Absolute and normalised; case-folded where the filesystem is.  Nim hands
  ## back symlink-resolved paths, and the root below is resolved the same way.
  result = normalizedPath(absolutePath(p))
  when defined(windows):
    result = result.replace('/', '\\').toLowerAscii()

proc isInside(child, parent: string): bool =
  let c = comparable(child)
  let p = comparable(parent)
  c.len > p.len and c.startsWith(p) and c[p.len] in {DirSep, AltSep}

proc sameDir(a, b: string): bool =
  comparable(a) == comparable(b)

proc canonical(p: string): string =
  try: expandFilename(p) except OSError: p

let selfFile = canonical(SelfSource)
var rootGuess = selfFile.parentDir
for _ in 1 .. LevelsBelowRoot:
  rootGuess = rootGuess.parentDir
let root = canonical(rootGuess)

let nimExe =
  if fileExists(CompilerAtBuild): CompilerAtBuild
  else: findExe("nim")

proc requireProbeable() =
  ## Refuse to report a verdict about an unknown tree or without a compiler.
  ## Called at the top of every case rather than at module scope, so that
  ## enumerating the cases never depends on it.
  if not fileExists(root / RootMarker):
    refuse("cannot locate the checkout root from " & SelfSource &
      " (derived " & root & ", which has no " & RootMarker &
      "): refusing to report a verdict about an unknown tree")
  if nimExe.len == 0:
    refuse("no `nim` to probe with (neither " & CompilerAtBuild &
      " nor one on PATH): refusing to report a verdict")
  echo "nimcache-locality: checkout ", root
  echo "nimcache-locality: probing with ", nimExe

proc nimcacheOf(workDir, project: string; extra: seq[string] = @[];
                env: StringTableRef = nil): string =
  ## The nimcache Nim would compile `project` into from `workDir`, as
  ## `nim dump` reports it; "" when the probe itself failed (already recorded).
  var args = @["dump", "--dump.format:json", "--hints:off"]
  args.add(extra)
  args.add(project)
  let what = "`nim " & args.join(" ") & "` in " & workDir
  var output = ""
  var code = -1
  try:
    let p = startProcess(nimExe, workingDir = workDir, args = args, env = env,
                         options = {poStdErrToStdOut})
    output = p.outputStream.readAll()
    code = p.waitForExit()
    p.close()
  except CatchableError as e:
    refuse("could not run " & what & ": " & e.msg)
    return ""
  if code != 0:
    refuse(what & " exited " & $code & ":\n" & output)
    return ""
  for line in output.splitLines():
    if line.startsWith("{"):
      try:
        return parseJson(line)["nimcache"].getStr()
      except CatchableError as e:
        refuse(what & " printed unparseable JSON (" & e.msg & "): " & line)
        return ""
  refuse(what & " printed no JSON:\n" & output)
  ""

proc expectedFor(projectRel, suffix: string): string =
  ## The layout config.nims promises: <checkout>/.nimcache/<rel dir>/<name><suffix>.
  let dir = projectRel.parentDir
  var d = root / ".nimcache"
  if dir.len > 0 and dir != ".":
    d = d / dir
  d / (projectRel.splitFile.name & suffix)

proc checkLayout(label, got, want: string) =
  if got.len == 0:
    return # the probe failure is already recorded
  if not isInside(got, root):
    refuse(label & ": resolves OUTSIDE the checkout, to " & got &
         " -- a cache every checkout on this machine shares")
  elif not sameDir(got, want):
    refuse(label & ": resolves to " & got & ", not the documented " & want)
  else:
    pass(label & " -> " & relativePath(got, root))

let selfRel = relativePath(selfFile, root).replace('\\', '/')

suite "nimcache locality":
  setup:
    failures = 0
    requireProbeable()
    require failures == 0

  teardown:
    if failures > 0:
      echo "nimcache-locality: FAILED, ", failures, " failure(s): a Nim ",
        "build in this checkout can reach a nimcache that other checkouts ",
        "share.  See the header of config.nims."

  test "self: this binary was compiled with a nimcache inside the checkout":
    if isInside(SelfNimcache, root):
      pass("this binary was compiled in " & relativePath(SelfNimcache, root))
    else:
      refuse("this test binary was compiled with the nimcache " &
        SelfNimcache & ", OUTSIDE the checkout: whatever built it bypassed " &
        "config.nims without naming a checkout-local --nimcache:")
    check failures == 0

  test "layout: nim dump reports the documented directory in debug and release":
    checkLayout(selfRel & " (from the checkout root)",
                nimcacheOf(root, selfRel), expectedFor(selfRel, "_d"))
    checkLayout(selfRel & " (from its own directory)",
                nimcacheOf(selfFile.parentDir, selfFile.extractFilename),
                expectedFor(selfRel, "_d"))
    for m in MainModules:
      if not fileExists(root / m):
        refuse(m & ": listed as a main module to probe, but it does not exist")
        continue
      checkLayout(m & " (debug)", nimcacheOf(root, m), expectedFor(m, "_d"))
      checkLayout(m & " (-d:release)", nimcacheOf(root, m, @["-d:release"]),
                  expectedFor(m, "_r"))
    check failures == 0

  test "layout: an explicit --nimcache: on the command line still wins":
    let explicitDir = getTempDir() / ("nimcache-locality-explicit-" &
      $getCurrentProcessId())
    let explicitGot = nimcacheOf(root, selfRel,
      @["--nimcache:" & explicitDir])
    check explicitGot.len > 0
    if explicitGot.len > 0:
      if sameDir(explicitGot, explicitDir):
        pass("an explicit --nimcache: on the command line still wins")
      else:
        refuse("an explicit --nimcache:" & explicitDir & " resolved to " &
          explicitGot & ": the config overrides the command line")
    check failures == 0

  test "control: with the repo-root config off the probe resolves outside":
    var controlEnv = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      controlEnv[k] = v
    let fakeXdg = getTempDir() / ("nimcache-locality-control-xdg-" &
      $getCurrentProcessId())
    controlEnv["XDG_CACHE_HOME"] = fakeXdg
    let controlGot = nimcacheOf(root, selfRel, @["--skipParentCfg"],
      controlEnv)
    check controlGot.len > 0
    if controlGot.len > 0:
      if isInside(controlGot, root):
        refuse("CONTROL did not fail: with the repo-root config switched " &
          "off the probe still reports " & controlGot & ", inside the " &
          "checkout -- so it cannot tell a shared cache from a local one, " &
          "and every verdict of the cases above is vacuous")
      else:
        when defined(posix):
          let want = fakeXdg / "nim" / (selfFile.splitFile.name & "_d")
          if sameDir(controlGot, want):
            pass("with the config off, this file resolves to Nim's shared " &
                 "default " & controlGot)
          else:
            refuse("CONTROL resolved outside the checkout but not to Nim's " &
              "default formula ($XDG_CACHE_HOME/nim/<project>_d): " &
              controlGot)
        else:
          pass("with the config off, this file resolves outside the " &
               "checkout: " & controlGot)
    check failures == 0
