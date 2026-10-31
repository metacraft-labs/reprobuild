## A cross-built prefix carries every library its images need except the C
## library (``scripts/cross/runtime_closure.sh``): ``bundle_runtime_closure``
## copies each DT_NEEDED (transitively) and the engine's dlopen names from
## the sysroot into ``<prefix>/lib`` and points every image's RUNPATH there,
## and ``check_prefix_closure`` refuses a prefix with anything unresolved.
## Before it, a cross-built engine loaded libclingo from whatever the
## target's base had installed (``could not load: libclingo.so`` on a base
## without it).
##
## The images here are host ELFs built by the host C compiler (the logic is
## architecture-independent); the cross build applies it to the target's.
## *Mocking.* A fake sysroot directory holding the host-built libraries:
## the real one is a copy of a target's /usr/lib, which a unit test cannot
## take.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packaging/runtime_contract
import repro_dsl_stdlib/packaging/types

const Script = currentSourcePath().parentDir.parentDir.parentDir /
  "scripts" / "cross" / "runtime_closure.sh"
const Triple = "x86_64-linux-gnu"

proc sh(cmd: string): tuple[output: string; code: int] =
  let r = execCmdEx("bash -c " & quoteShell(cmd))
  (r.output, r.exitCode)

proc tool(name: string): string = findExe(name)

suite "a cross-built prefix's runtime closure":
  test "needed libraries are bundled with a relative RUNPATH; a missing one is refused":
    let tmp = createTempDir("cross-closure-", "")
    defer: removeDir(tmp)
    let sysLib = tmp / "sysroot" / "usr" / "lib" / Triple
    let stage = tmp / "stage"
    createDir(sysLib)
    createDir(stage / "bin")
    createDir(stage / "lib")
    writeFile(tmp / "bar.c", "int bar(void) { return 2; }\n")
    writeFile(tmp / "foo.c", "int bar(void); int foo(void) { return bar() + 1; }\n")
    writeFile(tmp / "prog.c", "int foo(void); int main(void) { return foo() - 3; }\n")
    let cc = tool("cc")
    check sh(cc & " -shared -fPIC -Wl,-soname,libbar.so.1 -o " & sysLib / "libbar.so.1 " & tmp / "bar.c").code == 0
    check sh(cc & " -shared -fPIC -Wl,-soname,libfoo.so.2 -o " & sysLib / "libfoo.so.2 " & tmp / "foo.c" & " -L" & sysLib & " -l:libbar.so.1").code == 0
    check sh(cc & " -o " & stage / "bin" / "prog " & tmp / "prog.c" & " -L" & sysLib & " -Wl,-rpath-link," & sysLib & " -l:libfoo.so.2").code == 0
    # The engine's dlopen names: zstd from the sysroot, clingo already built.
    writeFile(sysLib / "libzstd.so.1", "")
    writeFile(stage / "lib" / "libclingo.so", "")
    let env = "READELF=" & quoteShell(tool("readelf")) & " PATCHELF=" &
      quoteShell(tool("patchelf")) & " "
    let run = proc(fn: string): tuple[output: string; code: int] =
      sh(env & "bash -c 'source " & Script & " && " & fn & "'")
    # Before bundling, the closure is open.
    let before = run("check_prefix_closure " & stage)
    check before.code != 0
    check "libfoo.so.2" in before.output
    check run("bundle_runtime_closure " & stage & " " & tmp / "sysroot" & " " & Triple).code == 0
    # Transitively: libbar, needed only by libfoo, came too.
    for n in ["libfoo.so.2", "libbar.so.1", "libzstd.so.1"]:
      checkpoint n
      check fileExists(stage / "lib" / n)
    check "$ORIGIN/../lib" in sh(tool("readelf") & " -d " & stage / "bin" / "prog").output
    check "$ORIGIN" in sh(tool("readelf") & " -d " & stage / "lib" / "libfoo.so.2").output
    check run("check_prefix_closure " & stage).code == 0
    # The prefix runs from anywhere: the RUNPATH, not the sysroot, finds them.
    removeDir(tmp / "sysroot")
    check sh(stage / "bin" / "prog").code == 0
    # A library that goes missing is refused by name.
    removeFile(stage / "lib" / "libbar.so.1")
    let after = run("check_prefix_closure " & stage)
    check after.code != 0
    check "libbar.so.1" in after.output

  test "the cross prefix checks exactly the dlopen names the packaging contract states":
    # One list in the bash helper, one in the packaging contract (the native
    # release's): they must not drift.
    var names: seq[string]
    for line in readFile(Script).splitLines():
      if line.startsWith("cross_dlopen_leaf_names=("):
        names = line["cross_dlopen_leaf_names=(".len ..< line.rfind(')')].splitWhitespace()
    check names == reprobuildDlopenLeafNames(toLinux)
