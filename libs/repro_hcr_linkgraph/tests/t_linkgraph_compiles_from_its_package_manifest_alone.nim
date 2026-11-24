## `repro_hcr_linkgraph` compiles for a consumer that knows only its package
## manifest.
##
## WHY.  The library is consumed from outside this repository: the
## reprobuild-cmake HCR gates compile a small reader against
## `repro_hcr_linkgraph/cmake_metadata`, with none of this checkout's
## `config.nims`. Since the library's modules started importing
## `repro_core` and `repro_hash`, a consumer that put only this library's
## `src` on its search path -- which is everything
## `repro_hcr_linkgraph.nimble` said it needed -- failed with
## `cannot open file: repro_core/paths`. The package manifest is the one
## statement a consumer can follow, so it must name every in-repo package
## the sources import, transitively.
##
## WHAT THIS CHECKS.
##   1. SUFFICIENT.  A consumer that imports every module of the library
##      compiles cleanly to C (`nim c --compileOnly`: every import resolved
##      and every module semantically checked, no C compiler involved)
##      with exactly the search paths obtained by following the `requires`
##      lines of `repro_hcr_linkgraph.nimble` through the
##      `libs/<name>/<name>.nimble` manifests of this checkout, and with
##      every other configuration source switched off
##      (`--skipUserCfg --skipParentCfg --skipProjCfg --noNimblePath`).
##   2. NECESSARY (and the control for 1).  Removing any one in-repo package
##      the library's manifest requires directly from that path set makes
##      the same probe fail with `cannot open file: <package>`. This proves
##      the probe really resolves imports through the derived paths only --
##      if a stray configuration supplied them, case 1 would pass vacuously
##      -- and that the manifest does not pad its `requires` list.
##
## The consumer is written to a fresh temporary directory outside the
## checkout, so no `config.nims` above it is this repository's.
##
## NO MOCKS: the real compiler, the real manifests and sources of this
## checkout. Cost: a handful of `nim c --compileOnly` runs, a few seconds
## each.
##
## Why `nim c --compileOnly` rather than `nim check`: the consumers this
## test stands for build with `nim c`, and `--compileOnly` runs that same
## front end -- including code generation for every generic instantiated
## across the library -- stopping only before the C compiler and linker,
## which the search path does not govern.

import std/[algorithm, os, osproc, sets, strutils, tempfiles, unittest]
from repro_core/process_streams import drainStream

const
  SelfSource = currentSourcePath()
  CompilerAtBuild = getCurrentCompilerExe()
  Library = "repro_hcr_linkgraph"
  LevelsBelowRoot = 3
    ## libs/repro_hcr_linkgraph/tests/<this file>
  RootMarker = "reprobuild.nimble"

let root = block:
  var r = SelfSource.parentDir
  for _ in 1 .. LevelsBelowRoot:
    r = r.parentDir
  r

let nimExe =
  if fileExists(CompilerAtBuild): CompilerAtBuild
  else: findExe("nim")

proc manifestPath(lib: string): string =
  root / "libs" / lib / (lib & ".nimble")

proc quotedStrings(line: string): seq[string] =
  ## Every `"..."` literal on a nimble line, in order.
  var i = 0
  while i < line.len:
    let open = line.find('"', i)
    if open < 0: break
    let close = line.find('"', open + 1)
    if close < 0: break
    result.add line[open + 1 ..< close]
    i = close + 1

proc manifestRequires(lib: string): seq[string] =
  ## Package names from every `requires` line of `lib`'s manifest, version
  ## constraints stripped (`"repro_core >= 0.1.0"` -> `repro_core`).
  ## https://github.com/nim-lang/nimble#creating-packages documents the
  ## `requires "name [constraint]", ...` form.
  for raw in readFile(manifestPath(lib)).splitLines():
    let line = raw.strip()
    if not line.startsWith("requires"): continue
    for spec in quotedStrings(line):
      let name = spec.strip().split({' ', '\t', '>', '<', '=', '~', '^', '#'})[0]
      if name.len > 0: result.add name

proc manifestSrcDir(lib: string): string =
  ## The manifest's `srcDir`, or "" when it declares none.
  for raw in readFile(manifestPath(lib)).splitLines():
    let line = raw.strip()
    if line.startsWith("srcDir"):
      let values = quotedStrings(line)
      if values.len > 0: return values[0]
  ""

proc isInRepoPackage(name: string): bool =
  fileExists(manifestPath(name))

proc requiredClosure(lib: string): seq[string] =
  ## In-repo packages reachable from `lib`'s manifest through `requires`,
  ## `lib` itself first. Packages that are not in `libs/` (`nim`) are not
  ## search-path entries and are left out.
  var seen = initHashSet[string]()
  var pending = @[lib]
  while pending.len > 0:
    let name = pending.pop()
    if name in seen or not isInRepoPackage(name): continue
    seen.incl name
    result.add name
    for dep in manifestRequires(name):
      pending.add dep

proc searchPath(lib: string): string =
  let src = manifestSrcDir(lib)
  if src.len == 0: root / "libs" / lib
  else: root / "libs" / lib / src

proc libraryModules(): seq[string] =
  ## Every importable module of the library: `<lib>` and `<lib>/<sub>...`.
  let src = searchPath(Library)
  result.add Library
  for path in walkDirRec(src / Library, relative = true):
    if path.endsWith(".nim"):
      result.add Library & "/" & path.changeFileExt("").replace('\\', '/')
  result.sort()

proc probe(packages: seq[string]): tuple[code: int, output: string] =
  ## Compile (to C only) a consumer importing every library module, with
  ## exactly the search paths of `packages` and no other configuration source.
  let dir = createTempDir("hcr_linkgraph_consumer_", "")
  defer: removeDir(dir)
  var body = ""
  for module in libraryModules():
    body.add "import " & module & "\n"
  writeFile(dir / "consumer.nim", body)
  var args = @["c", "--compileOnly", "--hints:off", "--skipUserCfg",
               "--skipParentCfg", "--skipProjCfg", "--noNimblePath",
               "--nimcache:" & (dir / "nimcache")]
  for pkg in packages:
    args.add "--path:" & searchPath(pkg)
  args.add dir / "consumer.nim"
  let p = startProcess(nimExe, workingDir = dir, args = args,
                       options = {poStdErrToStdOut})
  result.output = drainStream(p.outputStream)
  result.code = p.waitForExit()
  p.close()
  checkpoint("nim " & args.join(" ") & "\n-> exit " & $result.code & "\n" &
             result.output)

proc requireProbeable() =
  require fileExists(root / RootMarker)
  require fileExists(manifestPath(Library))
  require nimExe.len > 0

suite "repro_hcr_linkgraph package manifest":
  test "every module compiles with only the search paths its manifest declares":
    requireProbeable()
    let packages = requiredClosure(Library)
    checkpoint("derived package closure: " & packages.join(", "))
    let (code, _) = probe(packages)
    check code == 0

  test "every in-repo package the manifest requires directly is needed":
    requireProbeable()
    let closure = requiredClosure(Library)
    var direct: seq[string]
    for dep in manifestRequires(Library):
      if isInRepoPackage(dep): direct.add dep
    checkpoint("direct in-repo requirements: " & direct.join(", "))
    # The library imports in-repo packages; a manifest that names none of
    # them cannot pass case 1, and this case would check nothing.
    check direct.len > 0
    for dropped in direct:
      var reduced: seq[string]
      for pkg in closure:
        if pkg != dropped: reduced.add pkg
      let (code, output) = probe(reduced)
      check code != 0
      check ("cannot open file: " & dropped) in output
