## NPC-M7 verification `test_npc_nimble_dir_canary_never_resolves`
## (NPC-AREQ22, threat model G17).
##
## A package that exists ONLY under a planted `$HOME/.nimble/pkgs2` (in a
## private root that is this test's `HOME`; the real one is never touched)
## does not resolve in a Nim edge: the compile fails naming the missing
## module. The edge is a bare `nim c` with no `--noNimblePath` -- the shape
## of a hand-written compile -- so what keeps the canary out is the engine:
## the edge runs on a scratch `HOME` / `NIMBLE_DIR` of its own. And an edge
## whose argv names a path under the host's `$HOME/.nimble` (a `--path:` to
## the canary) is refused before it runs, naming the denied root.
##
## Positive control: the same `nim c`, run directly with that `HOME`,
## resolves the canary and the program prints its stamp -- so the canary is
## one the compiler would find.
##
## Falsifying mutation (recorded in the plan): removing the `HOME`
## redirection and the path denial (``preparedRunQuotaCommand``'s Nim edge
## isolation) makes the canary resolve and fails the test.
##
## No mock: the production engine, the host's Nim compiler.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_lock

const CanaryStamp = "NIMBLE-DIR-CANARY-1f3a"

proc nimEdge(id, cwd: string; extra: seq[string] = @[]): BuildAction =
  let nim = findExe("nim")
  var argv = @[nim, "c", "--skipUserCfg", "--skipParentCfg", "--hints:off"]
  argv.add extra
  argv.add @["--nimcache:" & (cwd / "nimcache-" & id),
    "--out:" & (cwd / ("app-" & id)), cwd / "app.nim"]
  action(id, argv, cwd = cwd, inputs = [cwd / "app.nim"],
    outputs = [cwd / ("app-" & id)], cacheable = false,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc runEdge(a: BuildAction; cacheRoot: string): ActionResult =
  var cfg = defaultBuildEngineConfig(cacheRoot)
  cfg.maxParallelism = 1
  cfg.bypassRunQuota = true
  let run = runBuild(graph([a]), cfg)
  for r in run.results:
    if r.id == a.id: return r

suite "NPC-M7: a Nim edge never reads Nimble's directory":
  let root = createTempDir("npc-m7-canary-", "")
  let home = root / "home"
  let canaryDir = home / ".nimble" / "pkgs2" /
    ("canary-1.0.0-" & repeat("ab", 20))
  createDir(canaryDir)
  writeFile(canaryDir / "canary.nim",
    "proc stamp*(): string = \"" & CanaryStamp & "\"\n")
  writeFile(canaryDir / "canary.nimble", "version = \"1.0.0\"\n")
  let work = root / "work"
  createDir(work)
  writeFile(work / "app.nim", "import canary\necho stamp()\n")
  let savedHome = getEnv("HOME")
  putEnv("HOME", home)

  test "control: the canary resolves for a compile that reads HOME":
    let nim = findExe("nim")
    check nim.len > 0
    let direct = execCmdEx(quoteShell(nim) & " c -r --skipUserCfg " &
      "--skipParentCfg --hints:off --nimcache:" &
      quoteShell(work / "nimcache-direct") & " --out:" &
      quoteShell(work / "app-direct") & " " & quoteShell(work / "app.nim"))
    checkpoint direct.output
    check direct.exitCode == 0
    check CanaryStamp in direct.output

  test "a Nim edge does not resolve it":
    let r = runEdge(nimEdge("edge", work), root / "engine-cache")
    checkpoint r.stderr & r.stdout
    check r.status == asFailed
    check "cannot open file: canary" in (r.stderr & r.stdout)
    check not fileExists(work / "app-edge")

  test "an edge naming the host's Nimble directory is refused":
    var refusal = ""
    try:
      let r = runEdge(nimEdge("named", work, @["--path:" & canaryDir]),
        root / "engine-cache")
      refusal = r.stderr & r.stdout
      check r.status == asFailed
    except CatchableError as e:
      refusal = e.msg
    checkpoint refusal
    check ("denied " & (home / ".nimble")) in refusal
    check not fileExists(work / "app-named")

  putEnv("HOME", savedHome)
