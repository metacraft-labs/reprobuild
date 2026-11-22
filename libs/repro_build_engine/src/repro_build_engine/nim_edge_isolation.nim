## Isolation of a Nim compile edge from Nimble's package directory
## (Nimble-Package-Catalog.md NPC-AREQ22).
##
## The Nim compiler is configured to search Nimble's directory by default:
## the installation's `config/nim.cfg` carries
## `nimblepath="$home/.nimble/pkgs2/"` (and, off Windows,
## `nimblepath="/opt/nimble/pkgs2/"`), and `--skipUserCfg --skipParentCfg`
## does not remove those lines -- the system configuration is still read.
## A package found there is one no lock names and no digest covers. So a Nim
## edge
##
## * passes `--noNimblePath` (the argv producers add it: the Nim convention
##   and the typed `nim` tool), which drops every `nimblepath` the
##   configuration names;
## * runs with `HOME` and `NIMBLE_DIR` set to a scratch directory of its own
##   (``nimEdgeHome``), so `$home` in a configuration, and anything that
##   reads `NIMBLE_DIR` (a project's `config.nims`), names nothing of the
##   host's;
## * treats the host's `$HOME/.nimble`, `/opt/nimble` and the host's
##   `NIMBLE_DIR` as denied paths (Sandbox-And-Monitoring.md § Policy Layer):
##   an argv that names one is refused before the edge runs, and an observed
##   read or probe of one fails the edge (``deniedNimbleAccess``).
##
## The scratch directory is the edge's own and is never shared with
## another edge: it is keyed by the action's id under the engine's cache
## root, and its `.nimble` is removed before each run, so nothing a
## previous run left there can be found.

import std/[hashes, os, strutils]

const
  NimEdgeIsolationVars* = ["HOME", "NIMBLE_DIR"]
    ## The variables a Nim edge receives on its scratch directory.
  NimEdgeHomeDirName = "nim-edge-home"

proc nimbleDeniedRoots*(hostHome, hostNimbleDir: string): seq[string] =
  ## The denied roots for a host whose `HOME` and `NIMBLE_DIR` are these
  ## ("" = unset): `$HOME/.nimble`, `/opt/nimble` (not on Windows), and
  ## `NIMBLE_DIR`. Absolute and normalized; each appears once.
  var roots: seq[string]
  if hostHome.len > 0 and hostHome.isAbsolute:
    roots.add normalizedPath(hostHome / ".nimble")
  when not defined(windows):
    roots.add "/opt/nimble"
  if hostNimbleDir.len > 0 and hostNimbleDir.isAbsolute:
    roots.add normalizedPath(hostNimbleDir)
  for r in roots:
    if r notin result: result.add r

proc hostNimbleDeniedRoots*(): seq[string] =
  ## ``nimbleDeniedRoots`` for the engine's own environment, which is the
  ## host's: the build is launched from it.
  nimbleDeniedRoots(getEnv("HOME"), getEnv("NIMBLE_DIR"))

proc underRoot(path, root: string): bool =
  let p = normalizedPath(path)
  p == root or p.startsWith(root & "/") or
    (DirSep != '/' and p.startsWith(root & $DirSep))

proc deniedRootOf*(path: string; roots: openArray[string]): string =
  ## The denied root ``path`` lies in, or "".
  if path.len == 0 or not path.isAbsolute:
    return ""
  for r in roots:
    if underRoot(path, r):
      return r
  ""

proc deniedArgvPath*(argv: openArray[string]; base: int;
                     roots: openArray[string]): tuple[arg, root: string] =
  ## The first compiler argument at or after ``base`` that names a path in a
  ## denied root: a bare path, or the value of an option (`--path:<p>`,
  ## `--nimblePath=<p>`, ...). Empty when none does.
  for i in base ..< argv.len:
    let a = argv[i]
    var candidates = @[a]
    let sep = a.find({':', '='})
    if a.startsWith("-") and sep > 0:
      candidates.add a[sep + 1 .. ^1]
    for c in candidates:
      let r = deniedRootOf(c, roots)
      if r.len > 0:
        return (a, r)
  ("", "")

proc nimEdgeHome*(cacheRoot, actionId: string): string =
  ## The scratch `HOME` of the Nim edge ``actionId``: one directory per
  ## action under the engine's cache root (else the temporary directory),
  ## created when missing, with any `.nimble` in it removed.
  let base =
    if cacheRoot.len > 0: cacheRoot / NimEdgeHomeDirName
    else: getTempDir() / ("repro-" & NimEdgeHomeDirName)
  let h = hash(actionId)
  result = base / toHex(uint32(cast[uint](h) and 0xffff_ffff'u), 8) &
    "-" & $actionId.len
  createDir(result)
  let nimbleDir = result / ".nimble"
  if dirExists(nimbleDir) or symlinkExists(nimbleDir):
    if symlinkExists(nimbleDir): removeFile(nimbleDir)
    else: removeDir(nimbleDir)

proc isolatedNimEdgeEnv*(env: seq[string]; home: string): seq[string] =
  ## ``env`` with `HOME` and `NIMBLE_DIR` naming ``home``. The launch
  ## applies the last value of a name, so the entries are appended after
  ## any the action declared.
  result = env
  for name in NimEdgeIsolationVars:
    result.add name & "=" & home

proc deniedNimbleAccess*(paths: openArray[string];
                         roots: openArray[string]): seq[string] =
  ## One diagnostic per observed path in a denied root.
  for p in paths:
    let r = deniedRootOf(p, roots)
    if r.len > 0:
      result.add "a Nim edge read " & p & ", in the denied " & r &
        " (Nimble's package directory is never an input of a build: a " &
        "package reaches a Nim compile only as a locked store path)"
