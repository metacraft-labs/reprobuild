## ``prependPath`` / ``appendPath`` move an entry; they never duplicate it.
##
## Two failures pull in opposite directions here, and both were observed on
## the same host within an hour of each other.
##
## Adding unconditionally is not idempotent, and activations NEST: a ``just``
## recipe whose Windows shell is ``repro exec -- bash`` re-enters the
## environment it is already inside, so every re-entry added the same
## thirty-five store entries again. Two levels is 3.6 KB of duplicate PATH,
## which is enough on its own to cross the 8191-character environment block
## cmd.exe silently truncates — surfacing as ``The input line is too long``
## and ``tsc is not recognized`` in a build that works one level down.
##
## Skipping an entry that is already present fixes that and breaks something
## worse. A recipe prepends precisely to change ORDER. Agent Harbor's MSVC
## contribution puts the Visual Studio toolset ahead of msys's ``usr/bin``,
## because Git for Windows ships a POSIX ``link`` there and rustc's linker
## step otherwise dies with ``/usr/bin/link: extra operand '...rcgu.o'`` — a
## coreutils usage error, from a program that is not a linker, about an
## object file. On a host that already carries Visual Studio somewhere in its
## ambient PATH, "already present, leave it alone" makes that contribution a
## no-op and brings the failure back.
##
## Moving satisfies both: applying an op twice yields the same list, and the
## entry ends up where the op said it should.

import std/[os, strtabs, strutils, unittest]

import repro_provider_runtime/types
import repro_dev_env_activation

const Sep = ";"

proc prepend(name, value: string): DevEnvShellOp =
  DevEnvShellOp(kind: deskPrependPath, name: name, value: value,
    separator: Sep)

proc append(name, value: string): DevEnvShellOp =
  DevEnvShellOp(kind: deskAppendPath, name: name, value: value,
    separator: Sep)

proc apply(start: string; ops: varargs[DevEnvShellOp]): string =
  let env = newStringTable(modeCaseInsensitive)
  env["P"] = start
  var cwd = ""
  for op in ops:
    env.applyShellOp(op, cwd)
  env["P"]

suite "dev-env path ops":
  test "prepending an absent entry puts it first":
    check apply("b;c", prepend("P", "a")) == "a;b;c"

  test "prepending a present entry moves it to the front":
    # The MSVC case: the directory is already somewhere in the ambient PATH,
    # behind the msys `usr/bin` that shadows `link`. The contribution exists
    # to reorder, so leaving it where it was would be the same as doing
    # nothing.
    check apply("b;a;c", prepend("P", "a")) == "a;b;c"

  test "prepending twice is the same as prepending once":
    check apply("b;c", prepend("P", "a"), prepend("P", "a")) == "a;b;c"

  test "a whole activation applied twice does not grow the list":
    let once = apply("host1;host2", prepend("P", "x"), prepend("P", "y"))
    let twice = apply("host1;host2",
      prepend("P", "x"), prepend("P", "y"),
      prepend("P", "x"), prepend("P", "y"))
    check once == twice
    check once.split(Sep).len == 4

  test "appending moves an entry to the end":
    check apply("a;b;c", append("P", "a")) == "b;c;a"

  test "appending twice is the same as appending once":
    check apply("a;b", append("P", "c"), append("P", "c")) == "a;b;c"

  test "an empty list takes the entry as-is":
    check apply("", prepend("P", "a")) == "a"
    check apply("", append("P", "a")) == "a"

  when defined(windows):
    test "a differently-cased spelling is the same entry":
      # The recipe writes `bin/Hostx64/x64` and the Visual Studio installer
      # writes `bin/HostX64/x64`. Treating those as two entries leaves the
      # duplicate the move exists to remove -- and on a PATH already near
      # the truncation limit, a duplicate is not free.
      check apply("C:/VS/bin/HostX64/x64;b",
        prepend("P", "C:/VS/bin/Hostx64/x64")) ==
        "C:/VS/bin/Hostx64/x64;b"

    test "resolveFromActivatedPath prefers Windows executable extensions over extensionless files":
      let tmpDir = getTempDir() / "repro_test_exe_res_" & $getCurrentProcessId()
      createDir(tmpDir)
      defer: removeDir(tmpDir)
      writeFile(tmpDir / "mytool", "#!/bin/sh\necho posix\n")
      writeFile(tmpDir / "mytool.cmd", "@echo off\necho win\n")
      let env = newStringTable(modeCaseInsensitive)
      env["PATH"] = tmpDir
      let resolved = resolveFromActivatedPath("mytool", env, "")
      check resolved == (tmpDir / "mytool.cmd")
