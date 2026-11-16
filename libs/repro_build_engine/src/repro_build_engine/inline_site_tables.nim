## The monitor shim's inline-syscall scan, done once per image per build.
##
## On Linux x86-64 the monitor shim decodes the executable sections of every
## image a monitored process runs, at start-up, to find and trap raw `syscall`
## instructions. A build runs the same compiler image once per compile, so it
## decoded the same bytes once per compile: about 0.13 s for GCC's `cc1`.
## io-mon lets a process that is not monitored compute that result once per
## image and hand it to the monitor host as a sealed memfd
## (`io_mon/inline_site_table`, `FsSnoopRequest.inlineSiteTables`); a shim then
## patches a mapping of a covered image from the table, and only when the
## mapped file, its code ranges and its code pages show that memory holds the
## bytes the table was computed from. Every other mapping is decoded as before.
##
## The engine is that process. This module keeps the tables of one build:
##
## * They are computed by the engine from the image files it opens itself,
##   never read from anything a monitored process could have written, and
##   kept in the engine's memory and in sealed memfds only. Nothing persists
##   past the build, so there is no table on disk for a monitored process to
##   replace for a later one.
## * Which images: the root image of every monitored action (which the
##   monitor's evidence never records), and every executable or shared object
##   a finished action was observed reading (the images its processes ran,
##   the libraries the loader opened). Choosing an image only decides where
##   the engine spends its CPU: a table is served by a shim only for the exact
##   file it describes.
## * The first wave. A build starts every ready compile at once, before any
##   has finished, so none would find a table for the compiler proper (`cc1`,
##   which the driver execs). So while the FIRST action whose root image lives
##   in a realized store prefix runs, other actions with the same root image
##   are held back (`holdsLaunch`): when it finishes, its evidence has named
##   the subprograms, they are tabled, and the held actions launch with them.
##   This costs the build one compile's latency once per such tool, and saves
##   a decode of the compiler in every compile of the first wave.
## * A file changed less than `defaultSettleNs` ago gets no table yet and is
##   tried again on a later launch.
##
## Linux x86-64 only. Elsewhere every entry point does nothing and no action
## is given a table.

import std/[os, sets, strutils, tables, times]
when defined(linux) and defined(amd64):
  # No `std/posix` here: in this library only the engine module may import
  # it (tests/integration/t_every_launch_path_is_monitored.nim), so even the
  # memfd's descriptor is closed through io-mon.
  import io_mon/inline_site_table
  import io_mon/hooks/linux_mapping_policy

type
  InlineSiteTables* = ref object
    ## The tables of one build. Owned by `runBuild`, closed when it returns.
    when defined(linux) and defined(amd64):
      images: seq[SiteTableImage]
      decided: HashSet[string]
        ## Paths this build has a table for, or has found not to be an image
        ## that can have one.
      tabled: HashSet[(uint64, uint64)]
        ## Device and inode of every tabled file: the same image reached
        ## under another spelling (a driver's `bin/../libexec/...` probe and
        ## its exec) is decoded once.
      retryAt: Table[string, float]
        ## Paths refused as changed too recently: when to try again.
      firstRuns: Table[string, string]
        ## Root image in a realized prefix -> the action running it first,
        ## while it runs. Other actions with that root image wait for it.
      learnedRoots: HashSet[string]
        ## Root images whose first run has finished.
      fds: seq[cint]
        ## Every published memfd, kept open until the build ends: a monitor
        ## host started with an older one may still be opening it.
      published: int
        ## `images.len` when the current memfd was published.
      path: string
        ## `/proc/<pid>/fd/<n>` of the current memfd, "" before the first.
      error*: string
        ## The last reason a memfd could not be published (diagnostic only:
        ## without a table every image is decoded, as before).

proc newInlineSiteTables*(): InlineSiteTables =
  InlineSiteTables()

proc close*(t: InlineSiteTables) =
  ## Release every memfd. A host still running keeps its own descriptor.
  when defined(linux) and defined(amd64):
    if t == nil:
      return
    for fd in t.fds:
      closeSiteTableFile(fd)
    t.fds.setLen(0)
    t.path = ""
  else:
    discard t

proc noteImage*(t: InlineSiteTables; path: string) =
  ## Compute the table of `path` if it is an executable or shared object the
  ## shim would scan and this build has not tabled it yet.
  when defined(linux) and defined(amd64):
    if t == nil or path.len == 0 or not path.isAbsolute or path in t.decided:
      return
    let retry = t.retryAt.getOrDefault(path, 0.0)
    if retry > 0.0 and epochTime() < retry:
      return
    # The shim never scans these (`shouldPatchInlineSyscallMapping`), so a
    # table for them would never be read.
    if isSystemRuntimeMappingPath(path) or isMonitorShimMappingPath(path):
      t.decided.incl path
      return
    var info: FileInfo
    try:
      info = getFileInfo(path, followSymlink = true)
    except OSError:
      t.decided.incl path
      return
    if info.kind != pcFile or info.size < 64:
      t.decided.incl path
      return
    if (uint64(info.id.device), uint64(info.id.file)) in t.tabled:
      t.decided.incl path
      return
    let computed = computeSiteTable(path)
    if computed.ok:
      t.images.add computed.image
      t.tabled.incl (computed.image.dev, computed.image.ino)
      t.decided.incl path
      t.retryAt.del path
    elif computed.reason == "changed too recently":
      t.retryAt[path] = epochTime() + float(defaultSettleNs) / 1e9
    else:
      t.decided.incl path
  else:
    discard t
    discard path

proc noteImages*(t: InlineSiteTables; paths: openArray[string]) =
  for path in paths:
    t.noteImage(path)

proc realizedPrefixOf(path: string): string =
  ## The realized store prefix holding `path`: the nearest ancestor carrying
  ## the store's `.repro-receipt`. "" when there is none.
  var dir = path.parentDir
  while dir.len > 1:
    if fileExists(dir / ".repro-receipt"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  ""

proc noteLaunch*(t: InlineSiteTables; rootImage, actionId: string) =
  ## A monitored action with this root image is about to launch. Table the
  ## root image, and when it lives in a realized store prefix and no action
  ## with it has run yet, make this the first run the others wait for.
  when defined(linux) and defined(amd64):
    if t == nil or rootImage.len == 0:
      return
    t.noteImage(rootImage)
    if rootImage in t.learnedRoots or t.firstRuns.hasKey(rootImage):
      return
    if realizedPrefixOf(rootImage).len > 0:
      t.firstRuns[rootImage] = actionId
  else:
    discard t
    discard rootImage
    discard actionId

proc firstRunPending*(t: InlineSiteTables;
                      stillRunning: proc(actionId: string): bool): bool =
  ## Whether any first run is still in flight; first runs that are no longer
  ## running are released for good. Lets the scheduler skip resolving root
  ## images entirely once no hold can apply (a warm build launches nothing).
  when defined(linux) and defined(amd64):
    if t == nil or t.firstRuns.len == 0:
      return false
    var finished: seq[string] = @[]
    for image, first in t.firstRuns:
      if not stillRunning(first):
        finished.add image
    for image in finished:
      t.firstRuns.del image
      t.learnedRoots.incl image
    t.firstRuns.len > 0
  else:
    discard t
    false

proc holdsLaunch*(t: InlineSiteTables; rootImage: string;
                  stillRunning: proc(actionId: string): bool): bool =
  ## Whether an action with this root image should wait: the first run of the
  ## image is still in flight. A first run that is no longer running (it
  ## finished, failed, or never started) releases the image for good.
  when defined(linux) and defined(amd64):
    if t == nil or rootImage.len == 0:
      return false
    let first = t.firstRuns.getOrDefault(rootImage, "")
    if first.len == 0:
      return false
    if stillRunning(first):
      return true
    t.firstRuns.del rootImage
    t.learnedRoots.incl rootImage
    false
  else:
    discard t
    discard rootImage
    false

proc currentPath*(t: InlineSiteTables): string =
  ## The `/proc/<pid>/fd/<n>` path of a sealed memfd holding every table this
  ## build has, publishing a new one when tables were added since the last.
  ## "" when there is none (nothing tabled yet, or publishing failed).
  when defined(linux) and defined(amd64):
    if t == nil or t.images.len == 0:
      return ""
    if t.images.len > t.published or t.path.len == 0:
      let made = createSealedSiteTableFile(encodeSiteTables(t.images))
      if made.fd < 0:
        t.error = made.error
        return t.path
      t.fds.add made.fd
      t.published = t.images.len
      t.path = "/proc/" & $getCurrentProcessId() & "/fd/" & $made.fd
    t.path
  else:
    discard t
    ""

proc tabledImageCount*(t: InlineSiteTables): int =
  ## How many images this build has tables for.
  when defined(linux) and defined(amd64):
    if t == nil: 0 else: t.images.len
  else:
    discard t
    0
