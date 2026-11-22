## NPC-M7 verification `test_npc_m7_system_nimblepath_canary_never_resolves`
## (threat model G17, NPC-M0 § 3, amendment A7 of NPC-AREQ22).
##
## The Nim installation's own `config/nim.cfg` names Nimble directories
## (`nimblepath="/opt/nimble/pkgs2/"`), and `--skipUserCfg --skipParentCfg`
## does not drop them. Here a private copy of the toolchain has a
## `nim.cfg` whose `nimblepath=` names a canary directory (the shape of the
## `/opt/nimble/pkgs2` line), and the build's `NIMBLE_DIR` names another
## canary, which the project's `config.nims` adds as a Nimble path. A
## `repro build` whose `nim.c` edge imports either canary fails, naming the
## missing module: the edge passes `--noNimblePath`, and runs on a scratch
## `NIMBLE_DIR`.
##
## Positive controls: the same compiles run directly with that toolchain
## (no `--noNimblePath`, the host's `NIMBLE_DIR`) resolve both canaries.
##
## Falsifying mutation (recorded in the plan): dropping `--noNimblePath`
## from the edge's argv (the typed `nim c` tool's `noNimblePath = true`)
## AND `NIMBLE_DIR` from the edge's redirected variables makes the canaries
## resolve and fails the test. Dropping `--noNimblePath` alone does not:
## the compiler reads `NIMBLE_DIR`, and with it set (to the edge's scratch
## directory) the installation's `nimblepath=` entries are not searched.
##
## Every directory is under a private root; the real `/opt/nimble`,
## `$HOME/.nimble` and the toolchain are never written.

import std/[os, osproc, strutils, unittest]

import ./nimble_m7_fixtures

const
  SysStamp = "SYSTEM-NIMBLEPATH-CANARY-7c1d"
  EnvStamp = "NIMBLE-DIR-ENV-CANARY-52e0"
  NimblePathConfig = """
switch("NimblePath", getEnv("NIMBLE_DIR") & "/pkgs2")
"""

proc canaryToolchain(root: string; nimblePath: string): string =
  ## A copy of the host's Nim whose `config/nim.cfg` also names
  ## ``nimblePath``. The library is the host's (a link); the binary and the
  ## configuration are copies. Returns the copy's `bin` directory.
  let real = expandFilename(findExe("nim"))
  let prefix = real.parentDir.parentDir
  let copy = root / "canary-nim"
  createDir(copy / "bin")
  copyFileWithPermissions(real, copy / "bin" / "nim")
  createSymlink(prefix / "lib", copy / "lib")
  createDir(copy / "config")
  for kind, path in walkDir(prefix / "config"):
    if kind in {pcFile, pcLinkToFile}:
      copyFile(path, copy / "config" / extractFilename(path))
  let cfg = copy / "config" / "nim.cfg"
  writeFile(cfg, readFile(cfg) & "\nnimblepath=\"" & nimblePath & "\"\n")
  copy / "bin"

proc plantCanary(dir, name, stamp: string) =
  let pkg = dir / "pkgs2" / (name & "-1.0.0-" & repeat("ef", 20))
  createDir(pkg)
  writeFile(pkg / (name & ".nim"), "proc stamp*(): string = \"" & stamp & "\"\n")
  writeFile(pkg / (name & ".nimble"), "version = \"1.0.0\"\n")

suite "NPC-M7: neither the toolchain's nimblepath nor NIMBLE_DIR reaches a Nim edge":
  test "both canaries are refused":
    var c = newCliWorld("m7-sysnimble")
    let f = newFixture("m7-sysnimble", c.mirrorRoutes)
    let sysDir = c.w.root / "opt-canary"
    let envDir = c.w.root / "nimbledir-canary"
    plantCanary(sysDir, "syscanary", SysStamp)
    plantCanary(envDir, "envcanary", EnvStamp)
    let bin = canaryToolchain(c.w.root, sysDir / "pkgs2/")
    let work = c.w.root / "direct"
    createDir(work)

    # Controls: the toolchain resolves the first canary by its own
    # configuration, and a config.nims reading NIMBLE_DIR the second.
    writeFile(work / "sys.nim", "import syscanary\necho stamp()\n")
    let sys = execCmdEx(quoteShell(bin / "nim") & " c -r --skipUserCfg " &
      "--skipParentCfg --hints:off --nimcache:" & quoteShell(work / "nc1") &
      " " & quoteShell(work / "sys.nim"))
    checkpoint sys.output
    check sys.exitCode == 0 and SysStamp in sys.output
    createDir(work / "env")
    writeFile(work / "env" / "config.nims", NimblePathConfig)
    writeFile(work / "env" / "env.nim", "import envcanary\necho stamp()\n")
    let envRun = execCmdEx("env NIMBLE_DIR=" & quoteShell(envDir) & " " &
      quoteShell(bin / "nim") & " c -r --skipUserCfg --skipParentCfg " &
      "--hints:off --nimcache:" & quoteShell(work / "nc2") & " " &
      quoteShell(work / "env" / "env.nim"))
    checkpoint envRun.output
    check envRun.exitCode == 0 and EnvStamp in envRun.output

    # The compiler reads `NIMBLE_DIR` itself: when it is set, the
    # installation's `nimblepath=` entries are not searched. So the
    # toolchain canary is built with NO `NIMBLE_DIR` in the build's
    # environment (only the edge's scratch one), and the `NIMBLE_DIR`
    # canary with the host's set -- each canary is kept out by its own
    # control, not by the other's.
    let sysEnv = cliEnv(c.w, f, @[("PATH", bin & ":" & getEnv("PATH"))])
    let envEnv = cliEnv(c.w, f, @[
      ("PATH", bin & ":" & getEnv("PATH")),
      ("NIMBLE_DIR", envDir)])
    for (module, stamp) in [("syscanary", SysStamp), ("envcanary", EnvStamp)]:
      let env = if module == "syscanary": sysEnv else: envEnv
      let dir = c.w.writeCliProject("app", @[],
        "import " & module & "\nwriteFile(\"build/app-out.txt\", stamp())\n")
      writeFile(dir / "config.nims", NimblePathConfig)
      let built = runRepro(env, dir, BuildArgs)
      checkpoint module & ":\n" & built.output
      check built.rc != 0
      check ("cannot open file: " & module) in built.output
      check not fileExists(dir / "build" / "app-out.txt")
      check stamp notin built.output
