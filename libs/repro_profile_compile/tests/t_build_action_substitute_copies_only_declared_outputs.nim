## A substituted build-action prefix may write only the action's declared
## outputs into its working directory, and never through a symbolic link.
##
## The apply path extracts a cache entry into a private directory and then
## copies it into the action's `cwd`. That copy runs inside a privileged apply
## and its input came from a cache, so it is treated as hostile. Four shapes of
## hostile prefix are checked here, each against a real extracted tree and a
## real working directory, with a real "outside" directory standing for
## anything the apply must not touch:
##
##   1. a declared output that is a link to a secret outside the prefix -- the
##      copy must not read the secret into the outputs;
##   2. an undeclared file (`.git/hooks/post-checkout`) -- it must not land in
##      the working directory;
##   3. a working directory whose declared output directory is a pre-existing
##      link to outside -- nothing may be written through it;
##   4. a pre-existing link at a declared output's path -- likewise.
##
## A positive control checks that an honest prefix (declared files and a
## declared directory, with an executable bit) still materialises
## byte-identically. No mocks: real files, links and permissions.

import std/[os, strutils, unittest]

import repro_profile
import repro_binary_cache_client
import repro_profile_compile/binary_cache_build_actions

proc fresh(name: string): tuple[root, extracted, cwd, outside: string] =
  let root = getTempDir() / ("substitute-outputs-" & name & "-" &
                             $getCurrentProcessId())
  removeDir(root)
  for d in ["extracted", "cwd", "outside"]:
    createDir(root / d)
  (root, root / "extracted", root / "cwd", root / "outside")

proc honestEntries(extractedDir: string): seq[ExtractedEntry] =
  ## The entry list an honest publisher's archive of `extractedDir` carries:
  ## an explicit directory entry per directory, a file entry per file.
  for path in walkDirRec(extractedDir, yieldFilter = {pcFile, pcDir},
                         relative = true):
    let rel = path.replace(DirSep, '/')
    if dirExists(extractedDir / path):
      result.add((path: rel, kind: aekDirectory))
    else:
      result.add((path: rel, kind: aekFile))

proc action(cwd: string; outputs: seq[string]): ProfileBuildAction =
  ProfileBuildAction(id: "edge", argv: @["/bin/true"], cwd: cwd,
                     outputs: outputs, cacheable: true)

suite "substituted outputs are copied only where declared, never through a link":
  test "a declared output that links to a secret outside is refused":
    let t = fresh("secret")
    defer: removeDir(t.root)
    writeFile(t.outside / "secret", "s3cr3t\n")
    createSymlink(t.outside / "secret", t.extracted / "out.bin")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted, honestEntries(t.extracted))
    check not fileExists(t.cwd / "out.bin")

  test "an undeclared file is refused and not written":
    let t = fresh("undeclared")
    defer: removeDir(t.root)
    writeFile(t.extracted / "out.bin", "artifact")
    createDir(t.extracted / ".git/hooks")
    writeFile(t.extracted / ".git/hooks/post-checkout", "#!/bin/sh\nevil\n")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted, honestEntries(t.extracted))
    check not fileExists(t.cwd / ".git/hooks/post-checkout")
    check not fileExists(t.cwd / "out.bin")

  test "a declared directory that is a pre-existing link to outside is refused":
    let t = fresh("dirlink")
    defer: removeDir(t.root)
    createDir(t.extracted / "bin")
    writeFile(t.extracted / "bin/tool", "tool")
    createSymlink(t.outside, t.cwd / "bin")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["bin"]), t.extracted, honestEntries(t.extracted))
    check not fileExists(t.outside / "tool")

  test "a pre-existing link at a declared output's path is refused":
    let t = fresh("filelink")
    defer: removeDir(t.root)
    writeFile(t.outside / "target", "original\n")
    writeFile(t.extracted / "out.bin", "artifact")
    createSymlink(t.outside / "target", t.cwd / "out.bin")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted, honestEntries(t.extracted))
    check readFile(t.outside / "target") == "original\n"

  test "positive control: an honest prefix materialises byte-identically":
    let t = fresh("honest")
    defer: removeDir(t.root)
    writeFile(t.extracted / "out.bin", "art\0ifact")
    createDir(t.extracted / "bin")
    writeFile(t.extracted / "bin/tool", "#!/bin/sh\n")
    setFilePermissions(t.extracted / "bin/tool",
      {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
       fpOthersRead, fpOthersExec})
    materialisePrefixIntoCwd(action(t.cwd, @["out.bin", "bin"]), t.extracted, honestEntries(t.extracted))
    check readFile(t.cwd / "out.bin") == "art\0ifact"
    check readFile(t.cwd / "bin/tool") == "#!/bin/sh\n"
    check fpUserExec in getFilePermissions(t.cwd / "bin/tool")
    check not symlinkExists(t.cwd / "out.bin")

suite "declared outputs are compared as normalised paths, and a file stays a file":
  test "`./out.bin` and `.` spellings are substitutable":
    let t = fresh("spelling")
    defer: removeDir(t.root)
    writeFile(t.extracted / "out.bin", "artifact")
    materialisePrefixIntoCwd(action(t.cwd, @["./out.bin"]), t.extracted,
                             @[(path: "out.bin", kind: aekFile)])
    check readFile(t.cwd / "out.bin") == "artifact"
    let t2 = fresh("dot")
    defer: removeDir(t2.root)
    writeFile(t2.extracted / "out.bin", "artifact")
    createDir(t2.extracted / "sub")
    writeFile(t2.extracted / "sub/x", "y")
    materialisePrefixIntoCwd(action(t2.cwd, @["."]), t2.extracted,
                             honestEntries(t2.extracted))
    check readFile(t2.cwd / "out.bin") == "artifact"
    check readFile(t2.cwd / "sub/x") == "y"

  test "a member below a declared file output is refused":
    # The archive carries no directory entry for `out.bin`: it was not a
    # directory output when it was packed, so `out.bin/x` must not turn the
    # declared file into a directory.
    let t = fresh("file-as-dir")
    defer: removeDir(t.root)
    createDir(t.extracted / "out.bin")
    writeFile(t.extracted / "out.bin/x", "sneaky")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted,
                               @[(path: "out.bin/x", kind: aekFile)])
    check not dirExists(t.cwd / "out.bin")
