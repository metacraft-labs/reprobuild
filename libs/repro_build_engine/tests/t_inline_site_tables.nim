## The engine's per-build inline site tables (`inline_site_tables`).
##
## The monitor shim decodes the code of every image a monitored process runs to
## find raw `syscall` instructions. The engine, which is not monitored,
## computes that result once per image per build and hands it to each
## monitored action as a sealed memfd; io-mon serves a mapping from it only
## when the mapped file is the one described (io-mon's own test,
## `tests/linux/test_io_mon_inline_site_table.nim`, grades that a served
## process is patched exactly as a scan patches it). This test grades the
## engine's side:
## * an executable is tabled from its own file, and the published memfd is
##   one io-mon's host accepts (sealed, of this build's scanner);
## * a file that is not an executable or shared object, or one the shim
##   never scans, is not tabled;
## * a file changed less than two seconds ago is not tabled yet, and is
##   tabled once it has settled;
## * the first launch of a toolchain image (one in a realized store prefix)
##   holds the other launches of that image until it is no longer running;
##   an image outside a realized prefix is never held.
##
## Linux x86-64 only, like the inline-syscall backend. No mocks: real
## executables (copies of this test's own binary), real memfd seals.

import std/[os, posix, unittest]

from repro_test_support import testCaseScratchSlug
import repro_test_support/reasoned_skip

import repro_build_engine/inline_site_tables
when defined(linux) and defined(amd64):
  import io_mon/inline_site_table

let TmpDir = absolutePath(
  "build/test-tmp/t_inline_site_tables-" & testCaseScratchSlug())

proc copyProgram(dest: string) =
  ## A real executable at `dest`, written now: a copy of this test's own
  ## binary (an ELF executable the build just linked). Copying gives a file
  ## whose change time the test controls, which the settling cases need.
  createDir(dest.parentDir)
  copyFileWithPermissions(getAppFilename(), dest)

proc settle() =
  sleep(int(defaultSettleNs div 1_000_000) + 200)

suite "the engine's inline site tables":
  when defined(linux) and defined(amd64):
    setup:
      if dirExists(TmpDir):
        removeDir(TmpDir)
      createDir(TmpDir)

    test "an executable is tabled and published as a table the host accepts":
      let exe = TmpDir / "prog"
      copyProgram(exe)
      writeFile(TmpDir / "header.h", "int x;\n")
      settle()
      let t = newInlineSiteTables()
      defer: t.close()
      check t.currentPath() == ""
      t.noteImage(TmpDir / "header.h")
      t.noteImage("/nix/store/does-not-matter/libc.so.6")
      check t.tabledImageCount() == 0
      t.noteImage(exe)
      check t.tabledImageCount() == 1
      t.noteImage(exe)
      check t.tabledImageCount() == 1
      let path = t.currentPath()
      check path.len > 0
      let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC)
      require fd >= 0
      defer: discard posix.close(fd)
      let identity = sealedSiteTableIdentity(fd)
      check identity.ok
      # The same tables are not published twice: nothing was added.
      check t.currentPath() == path
      # A second image publishes a new memfd holding both.
      let other = TmpDir / "prog2"
      copyProgram(other)
      settle()
      t.noteImage(other)
      check t.tabledImageCount() == 2
      check t.currentPath() != path

    test "one file reached under two spellings is decoded once":
      createDir(TmpDir / "bin")
      createDir(TmpDir / "libexec")
      let exe = TmpDir / "libexec" / "prog"
      copyProgram(exe)
      settle()
      let t = newInlineSiteTables()
      defer: t.close()
      t.noteImage(exe)
      t.noteImage(TmpDir & "/bin/../libexec/prog")
      check t.tabledImageCount() == 1

    test "a file changed too recently is tabled once it has settled":
      let exe = TmpDir / "fresh"
      copyProgram(exe)
      let t = newInlineSiteTables()
      defer: t.close()
      t.noteImage(exe)
      check t.tabledImageCount() == 0
      settle()
      t.noteImage(exe)
      check t.tabledImageCount() == 1

    test "the first launch of a toolchain image holds the others until it ends":
      let prefix = TmpDir / "prefixes" / "gcc" / "1.0"
      createDir(prefix / "bin")
      writeFile(prefix / ".repro-receipt", "receipt")
      let driver = prefix / "bin" / "cc-driver"
      copyProgram(driver)
      let loose = TmpDir / "loose-tool"
      copyProgram(loose)
      settle()
      let t = newInlineSiteTables()
      defer: t.close()
      var running = @["first"]
      let stillRunning = proc(id: string): bool = id in running
      check not t.firstRunPending(stillRunning)
      t.noteLaunch(driver, "first")
      check t.tabledImageCount() == 1
      check t.firstRunPending(stillRunning)
      check t.holdsLaunch(driver, stillRunning)
      # A second launch of the same image does not replace the first run.
      t.noteLaunch(driver, "second")
      check t.holdsLaunch(driver, stillRunning)
      running = @["second"]
      check not t.holdsLaunch(driver, stillRunning)
      check not t.firstRunPending(stillRunning)
      # Released for good: a later first-run candidate does not hold again.
      t.noteLaunch(driver, "third")
      running = @["third"]
      check not t.holdsLaunch(driver, stillRunning)
      # Outside a realized prefix nothing is held.
      t.noteLaunch(loose, "loose")
      running = @["loose"]
      check not t.holdsLaunch(loose, stillRunning)
  else:
    test "inline site tables (Linux x86-64 only)":
      skip("inline site tables exist only for the Linux x86-64 shim, " &
        "the one platform whose syscall scan decodes code")
