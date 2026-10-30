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

import std/[os, unittest]

import repro_profile
import repro_profile_compile/binary_cache_build_actions

proc fresh(name: string): tuple[root, extracted, cwd, outside: string] =
  let root = getTempDir() / ("substitute-outputs-" & name & "-" &
                             $getCurrentProcessId())
  removeDir(root)
  for d in ["extracted", "cwd", "outside"]:
    createDir(root / d)
  (root, root / "extracted", root / "cwd", root / "outside")

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
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted)
    check not fileExists(t.cwd / "out.bin")

  test "an undeclared file is refused and not written":
    let t = fresh("undeclared")
    defer: removeDir(t.root)
    writeFile(t.extracted / "out.bin", "artifact")
    createDir(t.extracted / ".git/hooks")
    writeFile(t.extracted / ".git/hooks/post-checkout", "#!/bin/sh\nevil\n")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted)
    check not fileExists(t.cwd / ".git/hooks/post-checkout")
    check not fileExists(t.cwd / "out.bin")

  test "a declared directory that is a pre-existing link to outside is refused":
    let t = fresh("dirlink")
    defer: removeDir(t.root)
    createDir(t.extracted / "bin")
    writeFile(t.extracted / "bin/tool", "tool")
    createSymlink(t.outside, t.cwd / "bin")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["bin"]), t.extracted)
    check not fileExists(t.outside / "tool")

  test "a pre-existing link at a declared output's path is refused":
    let t = fresh("filelink")
    defer: removeDir(t.root)
    writeFile(t.outside / "target", "original\n")
    writeFile(t.extracted / "out.bin", "artifact")
    createSymlink(t.outside / "target", t.cwd / "out.bin")
    expect IOError:
      materialisePrefixIntoCwd(action(t.cwd, @["out.bin"]), t.extracted)
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
    materialisePrefixIntoCwd(action(t.cwd, @["out.bin", "bin"]), t.extracted)
    check readFile(t.cwd / "out.bin") == "art\0ifact"
    check readFile(t.cwd / "bin/tool") == "#!/bin/sh\n"
    check fpUserExec in getFilePermissions(t.cwd / "bin/tool")
    check not symlinkExists(t.cwd / "out.bin")
