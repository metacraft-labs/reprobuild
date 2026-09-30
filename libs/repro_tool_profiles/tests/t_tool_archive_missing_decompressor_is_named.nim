## A compressed tool archive whose decompressor is absent fails by NAMING the
## decompressor, before ``tar`` runs.
##
## THE FAILURE THIS GUARDS, observed in recorder CI on both Linux and macOS
## runners (codetracer-cairo-recorder run 35150542759, linux-x64;
## codetracer-cardano-recorder run 35832387496, macos-arm64):
##
##   repro build: error: tool-resolution failed: tar listing failed for
##     .../tool-store/downloads/<sha>.archive using /nix/store/...-gnutar-1.35/bin/tar
##     attempt 1 (GNU: --force-local) exit=2: tar (child): xz: Cannot exec: ...
##     attempt 2 (no GNU-only flags) exit=2: tar (child): xz: Cannot exec: ...
##
## The ``tar`` on PATH was Nix's GNU tar. GNU tar does not decompress anything
## itself: for ``-z`` / ``-J`` / ``-j`` it execs ``gzip`` / ``xz`` / ``bzip2``
## from PATH, and the runner's dev-env PATH carried none of them. The message
## named the pre-flight LISTING, a content-addressed ``.archive`` file and a
## second ``tar`` attempt that could never have helped — the missing program
## was visible only inside tar's own child diagnostic. On macOS it read as a
## bsdtar/GNU-flag incompatibility, which it is not: the system ``/usr/bin/tar``
## (bsdtar, libarchive) was never run, because Nix's GNU tar shadowed it.
##
## WHAT IS ASSERTED
##
##   1. GNU tar + a ``.tar.xz`` / ``.tar.gz`` / ``.tar.bz2`` archive + a PATH
##      that holds ``tar`` but not the matching decompressor: extraction raises
##      an error that names the program (``xz`` / ``gzip`` / ``bzip2``), the
##      archive type, the archive path, the tar that needs it, and a remedy —
##      and the error is raised BEFORE tar runs (no ``Cannot exec`` transcript
##      in the message, no files in the destination).
##   2. The same archive with the decompressor present on PATH extracts, with
##      the real bytes. Without this, "refuse every compressed archive" would
##      pass (1).
##   3. An uncompressed ``.tar`` extracts on the decompressor-less PATH: the
##      check must not demand a program the archive type does not use.
##
## NO MOCKS. Real GNU tar, real xz/gzip/bzip2 (used only to BUILD the fixture
## archives), real archives, the real ``extractTarballArchive``. The single
## piece of arrangement is the PATH the product sees: a scratch directory that
## holds a symlink to GNU tar and, for case 2, symlinks to the decompressors.
## ``REPRO_HOST_TAR`` pins the tar to the GNU one so the case cannot silently
## exercise a different tar than it reports.
##
## Skip rule: no GNU tar, or no xz/gzip/bzip2 to build the fixtures with (the
## dev shell provides all of them). Windows is out of scope: its default tar is
## System32 bsdtar, which decompresses in-process.

import std/[os, osproc, strutils, unittest]

import repro_tool_profiles {.all.}
from repro_core/host_tar import HostTarOverrideEnv

proc gnuTarOnPath(): string =
  let t = findExe("tar")
  if t.len == 0: return ""
  let r = execCmdEx(quoteShell(t) & " --version")
  if r.exitCode == 0 and "GNU tar" in r.output: t else: ""

proc sh(cmd: string) =
  let r = execCmdEx(cmd)
  doAssert r.exitCode == 0, cmd & "\n" & r.output

proc linkInto(dir, exe: string) =
  createSymlink(exe, dir / extractFilename(exe))

when defined(windows):
  echo "SKIP: GNU-tar decompressor lookup is a POSIX concern"
else:
  let gnuTar = gnuTarOnPath()
  let xzExe = findExe("xz")
  let gzipExe = findExe("gzip")
  let bzip2Exe = findExe("bzip2")
  if gnuTar.len == 0 or xzExe.len == 0 or gzipExe.len == 0 or bzip2Exe.len == 0:
    echo "SKIP: needs GNU tar, xz, gzip and bzip2 on PATH (the dev shell has them)"
  else:
    let root = getTempDir() / ("t-decompressor-named-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "payload" / "pkg" / "bin")
    writeFile(root / "payload" / "pkg" / "bin" / "tool", "payload-bytes\n")
    let payloadDir = root / "payload"
    let kinds = @[("tar.xz", "-cJf", "xz", xzExe),
                  ("tar.gz", "-czf", "gzip", gzipExe),
                  ("tar.bz2", "-cjf", "bzip2", bzip2Exe)]
    for (typ, flag, _, _) in kinds:
      sh(quoteShell(gnuTar) & " " & flag & " " &
        quoteShell(root / ("fixture." & typ)) & " -C " & quoteShell(payloadDir) &
        " pkg")
    sh(quoteShell(gnuTar) & " -cf " & quoteShell(root / "fixture.tar") &
      " -C " & quoteShell(payloadDir) & " pkg")

    # The tool store names downloads `<sha>.archive`; mirror that so the type
    # can only come from `archiveType`, never from the file name.
    proc stage(typ: string): string =
      result = root / (typ.replace(".", "-") & ".archive")
      copyFile(root / ("fixture." & typ), result)

    let bareBin = root / "bin-tar-only"
    createDir(bareBin)
    linkInto(bareBin, gnuTar)
    let fullBin = root / "bin-with-decompressors"
    createDir(fullBin)
    linkInto(fullBin, gnuTar)
    for (_, _, _, exe) in kinds: linkInto(fullBin, exe)

    let savedPath = getEnv("PATH")
    let savedTar = getEnv(HostTarOverrideEnv)
    putEnv(HostTarOverrideEnv, gnuTar)

    suite "compressed tool archive with no decompressor on PATH":
      teardown:
        putEnv("PATH", savedPath)

      for (typ, _, prog, _) in kinds:
        test "GNU tar + " & typ & " + no '" & prog & "' names the program":
          let archive = stage(typ)
          let dest = root / ("dest-missing-" & typ)
          putEnv("PATH", bareBin)
          var msg = ""
          try:
            extractTarballArchive(archive, dest, typ, 0)
          except CatchableError as e:
            msg = e.msg
          putEnv("PATH", savedPath)
          check msg.len > 0
          check ("no '" & prog & "' decompressor") in msg
          check typ in msg
          check archive in msg
          check gnuTar in msg
          check "install " & prog in msg
          # Named BEFORE tar ran: no child-exec transcript, nothing extracted.
          check "Cannot exec" notin msg
          check not fileExists(dest / "pkg" / "bin" / "tool")

        test "GNU tar + " & typ & " + '" & prog & "' on PATH extracts":
          let archive = stage(typ)
          let dest = root / ("dest-present-" & typ)
          putEnv("PATH", fullBin)
          extractTarballArchive(archive, dest, typ, 0)
          putEnv("PATH", savedPath)
          check readFile(dest / "pkg" / "bin" / "tool") == "payload-bytes\n"

      test "an uncompressed tar needs no decompressor":
        let archive = stage("tar")
        let dest = root / "dest-plain"
        putEnv("PATH", bareBin)
        extractTarballArchive(archive, dest, "tar", 0)
        putEnv("PATH", savedPath)
        check readFile(dest / "pkg" / "bin" / "tool") == "payload-bytes\n"

    if savedTar.len > 0: putEnv(HostTarOverrideEnv, savedTar)
    else: delEnv(HostTarOverrideEnv)
    removeDir(root)
