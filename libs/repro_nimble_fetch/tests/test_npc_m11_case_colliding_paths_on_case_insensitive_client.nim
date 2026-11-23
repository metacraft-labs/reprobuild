## NPC-M11 adversarial audit: two paths of one source tree that differ only
## in letter case, fetched by a client whose store is on a case-insensitive
## file system (threat model G31; the shape macOS and Windows clients have).
##
## Git trees are case-sensitive, so an author can ship both `src/Foo.nim`
## and `src/foo.nim`, or a link `Lib -> src` beside a directory `lib/`. A
## case-sensitive client extracts each as its own entry. A case-insensitive
## one would fold them together: the second file replaces the first, or a
## member under `lib/` is written through the link `Lib`. Neither may be
## installed as the locked tree:
##
## * the two files: the folded tree is not the locked digest, so the fetch
##   is refused as a mismatch and nothing reaches the store;
## * the link and the directory: the member under `lib/` is refused before
##   it is written, because the path already exists as a link
##   (`refuseWriteThroughSymlink` asks the file system, which folds case).
##
## Positive control: the same two objects install on a case-sensitive store.
##
## The case-insensitive store is real, not simulated: a child of this test
## runs in a user and mount namespace of its own (`unshare -rm`), mounts a
## tmpfs with `casefold` there and marks the store directory case-folding
## (`FS_CASEFOLD_FL`, as `chattr +F` does), then fetches into it. The mirror
## is a directory outside that mount; nothing is fetched over a network.

import std/[os, osproc, strutils, tempfiles, unittest]

import ./fetch_fixtures
import repro_test_support/reasoned_skip

from repro_core/process_streams import drainStream

when defined(linux):
  proc c_mount(source, target, fstype: cstring; flags: culong;
               data: cstring): cint {.importc: "mount",
               header: "<sys/mount.h>".}
  proc c_ioctl(fd: cint; request: culong; arg: pointer): cint {.importc: "ioctl",
               header: "<sys/ioctl.h>", varargs.}
  proc c_open(path: cstring; flags: cint): cint {.importc: "open",
              header: "<fcntl.h>", varargs.}
  proc c_close(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
  var O_RDONLY {.importc, header: "<fcntl.h>".}: cint
  var O_DIRECTORY {.importc, header: "<fcntl.h>".}: cint
  const
    FsIocGetFlags = culong(0x80086601) ## _IOR('f', 1, long)
    FsIocSetFlags = culong(0x40086602) ## _IOW('f', 2, long)
    FsCasefoldFl = clong(0x40000000)

  proc makeCaseFolding(dir: string) =
    let fd = c_open(dir.cstring, O_RDONLY or O_DIRECTORY)
    doAssert fd >= 0, "open " & dir & ": " & osErrorMsg(osLastError())
    var flags: clong
    doAssert c_ioctl(fd, FsIocGetFlags, addr flags) == 0,
      "FS_IOC_GETFLAGS: " & osErrorMsg(osLastError())
    flags = flags or FsCasefoldFl
    doAssert c_ioctl(fd, FsIocSetFlags, addr flags) == 0,
      "FS_IOC_SETFLAGS (casefold): " & osErrorMsg(osLastError())
    discard c_close(fd)

proc childFetch(mount, mirrorDir: string; rows: seq[NimbleLockRow];
                caseInsensitive: bool) =
  ## In the child: the store on ``mount`` (case-folding when asked), each
  ## row fetched from the directory mirror; one result line per row.
  when defined(linux):
    if caseInsensitive:
      doAssert c_mount("tmpfs", mount.cstring, "tmpfs", 0, "casefold") == 0,
        "mount tmpfs casefold: " & osErrorMsg(osLastError())
    createDir(mount / "store")
    if caseInsensitive:
      makeCaseFolding(mount / "store")
      # The probe the whole test rests on: the store folds case.
      writeFile(mount / "store" / "Probe", "x")
      doAssert fileExists(mount / "store" / "pROBE"),
        "the store does not fold case"
      removeFile(mount / "store" / "Probe")
  for row in rows:
    var cfg = FetchConfig(stateDir: mount / "state-" & row.name,
      storeRoot: mount / "store", mirrors: @[parseMirror(mirrorDir)],
      originPolicy: defaultPolicy(), gitBin: findExe("git"),
      limits: DefaultExtractLimits)
    cfg = cfg.withNoOrigin()
    let r = fetchLocked(@[row], cfg)
    var line = "RESULT " & row.name & " ok=" & $r.ok
    for a in r.packages[0].attempts:
      line.add " attempt=" & $a.transport & ":" & $a.outcome & ":" & a.rule
    line.add " entry=" & $dirExists(entryPath(mount / "store", row.tree))
    line.add " staging=" & $stagingLeft(mount / "store").len
    echo line
    for a in r.packages[0].attempts:
      echo "DETAIL ", row.name, " ", a.detail.replace("\n", " ")

proc rowsFile(rows: seq[NimbleLockRow]): string =
  for r in rows:
    result.add [r.name, r.origin, r.commit, r.tree, r.archiveSha256,
      $r.size].join("\t") & "\n"

proc rowsOf(text: string): seq[NimbleLockRow] =
  for l in text.splitLines():
    if l.len == 0: continue
    let p = l.split('\t')
    result.add NimbleLockRow(name: p[0], origin: p[1], commit: p[2],
      tree: p[3], archiveSha256: p[4], size: parseBiggestInt(p[5]))

proc runChild(mount, mirrorDir, rows: string;
              caseInsensitive: bool): tuple[code: int; output: string] =
  var cmd: string
  var args: seq[string]
  if caseInsensitive:
    cmd = findExe("unshare")
    doAssert cmd.len > 0, "unshare(1) is needed for a private mount namespace"
    args = @["-rm", getAppFilename()]
  else:
    cmd = getAppFilename()
  args.add ["--child", mount, mirrorDir, rows,
    (if caseInsensitive: "ci" else: "cs")]
  let p = startProcess(cmd, args = args, options = {poStdErrToStdOut})
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (code, output)

proc resultLine(output, name: string): string =
  for l in output.splitLines():
    if l.startsWith("RESULT " & name & " "): return l
  ""

if paramCount() >= 5 and paramStr(1) == "--child":
  childFetch(paramStr(2), paramStr(3), rowsOf(readFile(paramStr(4))),
    paramStr(5) == "ci")
  quit(0)

suite "NPC-M11: case-colliding paths on a case-insensitive client":
  test "two files one case apart, and a link beside a directory of its name, are not installed":
    when not defined(linux):
      skip("a case-folding file system on Linux (tmpfs `casefold` in a private mount namespace) is what this test builds its store on")
    else:
      let f = newFixture("m11-casefold")
      let work = createTempDir("npc-m11-casefold-", "")
      let mirrorDir = work / "mirror"
      let mirror = parseMirror(mirrorDir)
      let twoFiles = f.package("owner/twofiles.git", @[
        nimbleFile("twofiles"),
        file("src/Foo.nim", "proc which*(): string = \"upper\"\n"),
        file("src/foo.nim", "proc which*(): string = \"lower\"\n")])
      let throughLink = f.package("owner/throughlink.git", @[
        nimbleFile("throughlink"),
        file("src/throughlink.nim", "discard\n"),
        symlink("Lib", "src"),
        file("lib/planted.nim", "discard\n")])
      mirror.putSource(twoFiles)
      mirror.putSource(throughLink)
      let rows = @[f.rowOf("twofiles", twoFiles),
        f.rowOf("throughlink", throughLink)]
      writeFile(work / "rows.tsv", rowsFile(rows))

      # Positive control: a case-sensitive store installs both trees.
      createDir(work / "cs")
      let cs = runChild(work / "cs", mirrorDir, work / "rows.tsv", false)
      checkpoint cs.output
      check cs.code == 0
      check "ok=true" in resultLine(cs.output, "twofiles")
      check "entry=true" in resultLine(cs.output, "twofiles")
      check "ok=true" in resultLine(cs.output, "throughlink")
      check "entry=true" in resultLine(cs.output, "throughlink")
      let csTwo = entryPath(work / "cs" / "store", twoFiles.tree)
      check readFile(csTwo / "src" / "Foo.nim") != readFile(csTwo / "src" / "foo.nim")

      # The case-insensitive store: neither tree is installed.
      createDir(work / "ci")
      let ci = runChild(work / "ci", mirrorDir, work / "rows.tsv", true)
      checkpoint ci.output
      check ci.code == 0
      let two = resultLine(ci.output, "twofiles")
      check "ok=false" in two
      check "attempt=mirror:mismatch" in two
      check "entry=false" in two
      check "staging=0" in two
      let link = resultLine(ci.output, "throughlink")
      check "ok=false" in link
      check "attempt=mirror:refused:through-link" in link
      check "entry=false" in link
      check "staging=0" in link
      # The mount was the child's own: nothing is left on this side of it.
      check not dirExists(work / "ci" / "store")
