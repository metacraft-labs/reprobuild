## An installed reprobuild prefix compiles profiles with the Nim it ships
## (``installedNimCompiler``): ``<prefix>/nim/bin/nim``, else
## ``<prefix>/bin/nim``, and only for a prefix that is a reprobuild install
## (``share/repro``). Before it, an installed engine run with a clean
## environment (a dynamic user's transient unit, ``PATH`` systemd's default)
## found no compiler unless the base had one on ``PATH`` -- measured on an
## armhf add-on test bed: "no Nim compiler".
##
## *Mocking.* None: real directories and files.

import std/[os, tempfiles, unittest]

import repro_profile_compile/compile

suite "the profile compile finds the installed prefix's Nim":
  test "the prefix's own nim is found; a non-reprobuild prefix is ignored":
    let tmp = createTempDir("installed-nim-", "")
    defer: removeDir(tmp)
    let prefix = tmp / "repro"
    createDir(prefix / "nim" / "bin")
    createDir(prefix / "bin")
    writeFile(prefix / "nim" / "bin" / "nim", "")
    writeFile(prefix / "bin" / "nim", "")
    # Not an install yet (no share/repro): not used.
    check installedNimCompiler([prefix]) == ""
    createDir(prefix / "share" / "repro")
    check installedNimCompiler([prefix]) == prefix / "nim" / "bin" / "nim"
    removeFile(prefix / "nim" / "bin" / "nim")
    check installedNimCompiler([prefix]) == prefix / "bin" / "nim"
    # A distribution prefix (/usr-like, no share/repro) is skipped.
    let usr = tmp / "usr"
    createDir(usr / "bin")
    writeFile(usr / "bin" / "nim", "")
    check installedNimCompiler([usr, prefix]) == prefix / "bin" / "nim"
