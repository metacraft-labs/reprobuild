## Which Windows pipe names are the input side of an MSYS2 or Cygwin
## pseudo-terminal.
##
## On Windows `repro shell` takes standard input for a terminal when it is a
## console, or a pipe named `\msys-<hex>-pty<N>-from-master` or
## `\cygwin-<hex>-pty<N>-from-master` (`stdin_terminal`). The name test is
## pure, so it runs on every operating system; the console and pipe queries
## around it need Windows and are not exercised here.

import std/unittest

import repro_cli_support/stdin_terminal

suite "an MSYS2 / Cygwin pty input pipe is recognised by its name":
  test "the input pipes of MSYS2 and Cygwin ptys are terminals":
    for name in [
        "\\msys-dd50a72ab4668b33-pty0-from-master",
        "\\msys-1888ae32e00d56aa-pty12-from-master",
        "\\cygwin-e022582115c10879-pty3-from-master",
        "\\cygwin-ABCDEF0123456789-pty0-from-master",
        "\\msys-a-pty9-from-master"]:
      checkpoint(name)
      check isMsysPtyInputPipeName(name)

  test "other pipe names are not":
    for name in [
        "",
        "\\",
        # The output side of a pty, not standard input.
        "\\msys-dd50a72ab4668b33-pty0-to-master",
        # No leading separator.
        "msys-dd50a72ab4668b33-pty0-from-master",
        # Missing or malformed parts.
        "\\msys--pty0-from-master",
        "\\msys-dd50a72ab4668b33-pty-from-master",
        "\\msys-xyz-pty0-from-master",
        "\\msys-dd50a72ab4668b33-tty0-from-master",
        "\\msys-dd50a72ab4668b33-pty0-from-master-extra",
        "\\msys-dd50a72ab4668b33-pty0-from-maste",
        # Another prefix, or the pattern inside a longer name.
        "\\mingw-dd50a72ab4668b33-pty0-from-master",
        "\\MSYS-dd50a72ab4668b33-pty0-from-master",
        "\\my-msys-dd50a72ab4668b33-pty0-from-master",
        # Ordinary anonymous and named pipes.
        "\\Win32Pipes.000012f4.00000002",
        "\\some-pipe-with-pty-in-its-name"]:
      checkpoint(name)
      check not isMsysPtyInputPipeName(name)
