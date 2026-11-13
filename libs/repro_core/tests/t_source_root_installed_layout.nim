## `repro_core/source_root`: the installed-layout arm of
## `resolveReprobuildSourceRoot` and the rule that keeps a copied image from
## reaching back into the checkout it was built in
## (Gradual-Nix-To-Reprobuild-Migration GM1w).
##
## A release archive (`reprobuild-<ver>-<os>-<arch>.{zip,tar.gz}`) has no
## wrapper to set `$REPROBUILD_SOURCE_ROOT`; on Windows `repro.exe` is run
## directly. The resolver therefore finds `<prefix>/share/repro/source` from
## where the running image lives (`<prefix>/bin/<exe>`). These cases pin:
##
## * the pure layout helpers on a fixture prefix;
## * the arm itself, by COPYING this test executable into a fixture
##   `<prefix>/bin` and running it as a child with every source-root variable
##   removed and its working directory outside any reprobuild tree -- the
##   operating system's own answer to "where is my image" is the anchor, as it
##   is for the real `reprobuild.exe`;
## * its precedence below an explicit `$REPROBUILD_SOURCE_ROOT`;
## * that the same copy, in a prefix WITHOUT `share/repro/source`, resolves
##   nothing -- not the checkout this test was compiled in, which exists on
##   this machine -- and that the search report names the probed
##   `share/repro/source` path and the variables that would select a tree;
## * that a copy which declares the image it stands in for
##   (`declareRunningImageSource`, as the dev-mode daemon does for its staged
##   engine) resolves exactly as that image would: the build checkout, or the
##   installed layout beside it.
##
## Mocks: none. Real directories, a real copied executable, real child
## processes.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_core/source_root
from repro_core/process_streams import drainStream

const ChildFlag = "--source-root-child"

if paramCount() in 1 .. 2 and paramStr(1) == ChildFlag:
  # The parent removed every source-root variable from this process's
  # environment and started it outside any reprobuild tree, unless the case
  # under test sets `REPROBUILD_SOURCE_ROOT` deliberately. A second argument
  # is the image this copy stands in for, declared the way the dev-mode
  # daemon declares the engine it staged a copy of.
  if paramCount() == 2:
    declareRunningImageSource(paramStr(2))
  echo "RESOLVED=", resolveReprobuildSourceRoot()
  echo "UNDER_COMPILED=", runningImageIsUnder(CompiledSourceRoot)
  echo "REPORT-BEGIN"
  stdout.write describeReprobuildSourceRootSearch()
  echo "REPORT-END"
  quit(0)

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

proc makeInstalledPrefix(prefix: string; trees: openArray[string]) =
  ## The markers the resolver checks: `libs/repro_project_dsl/src` and its
  ## entry module, under `share/repro/source`.
  touch(prefix / InstalledSourceRootSubdir / "libs" / "repro_project_dsl" /
    "src" / "repro_project_dsl.nim")
  for rel in trees:
    createDir(prefix / InstalledSourceTreesSubdir / rel)

proc runCopiedImage(prefix, cwd: string;
                    extraEnv: openArray[(string, string)] = [];
                    declaredSource = ""):
    tuple[output: string; exitCode: int] =
  ## Copy this executable to `<prefix>/bin/` and run it with every
  ## `REPROBUILD_*` variable and the public-CLI anchor removed. A non-empty
  ## `declaredSource` is passed to the child's `declareRunningImageSource`.
  let exe = prefix / "bin" / extractFilename(getAppFilename())
  createDir(exe.parentDir)
  copyFile(getAppFilename(), exe)
  inclFilePermissions(exe, {fpUserExec})
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.toUpperAscii.startsWith("REPROBUILD_") or
        k.toUpperAscii == PublicCliPathEnvVar:
      continue
    env[k] = v
  for (k, v) in extraEnv:
    env[k] = v
  var args = @[ChildFlag]
  if declaredSource.len > 0:
    args.add declaredSource
  let p = startProcess(exe, workingDir = cwd, args = args, env = env,
    options = {poStdErrToStdOut})
  result.output = drainStream(p.outputStream)
  result.exitCode = p.waitForExit()
  p.close()

proc field(output, name: string): string =
  for line in output.splitLines:
    if line.startsWith(name & "="):
      return line[name.len + 1 .. ^1]

suite "repro_core/source_root: installed layout helpers":

  test "a prefix's source root and the input trees it actually ships":
    let prefix = createTempDir("repro-core-layout-", "")
    defer: removeDir(prefix)
    makeInstalledPrefix(prefix, ["io-mon/src", "bearssl"])
    check installedLayoutSourceRoot(prefix) == prefix / InstalledSourceRootSubdir
    let trees = installedLayoutPackageTrees(prefix)
    check trees == @[
      ("BEARSSL_SRC", prefix / InstalledSourceTreesSubdir / "bearssl"),
      ("IO_MON_SRC", prefix / InstalledSourceTreesSubdir / "io-mon/src")]
    let roots = installedLayoutSourceRoots(prefix)
    check roots[0] == (ReprobuildSourceRootEnvVar,
      prefix / InstalledSourceRootSubdir)
    check roots[1 .. ^1] == trees

  test "input trees without reprobuild's own libs are not a layout":
    let prefix = createTempDir("repro-core-no-layout-", "")
    defer: removeDir(prefix)
    createDir(prefix / InstalledSourceTreesSubdir / "io-mon/src")
    check installedLayoutSourceRoot(prefix) == ""
    check installedLayoutPackageTrees(prefix).len == 0
    check installedLayoutPackageTrees("").len == 0

  test "the prefix of an installed source root, however it is spelled":
    let prefix = createTempDir("repro-core-prefix-of-", "")
    defer: removeDir(prefix)
    makeInstalledPrefix(prefix, [])
    let root = prefix / InstalledSourceRootSubdir
    check installedLayoutPrefixOfSourceRoot(root) == prefix
    check installedLayoutPrefixOfSourceRoot(root & $DirSep) == prefix
    when defined(windows):
      check installedLayoutPrefixOfSourceRoot(root.replace('\\', '/')).
        replace('/', '\\') == prefix
    # A checkout-shaped root, and a `share/repro/source` without the libs,
    # are not installed layouts.
    check installedLayoutPrefixOfSourceRoot(prefix) == ""
    check installedLayoutPrefixOfSourceRoot("") == ""
    let bare = createTempDir("repro-core-prefix-bare-", "")
    defer: removeDir(bare)
    createDir(bare / InstalledSourceRootSubdir)
    check installedLayoutPrefixOfSourceRoot(bare / InstalledSourceRootSubdir) == ""

suite "repro_core/source_root: resolver arm for an installed image":

  test "an image in <prefix>/bin resolves <prefix>/share/repro/source":
    let prefix = createTempDir("repro core installed ", "")
    let cwd = createTempDir("repro-core-cwd-", "")
    defer:
      removeDir(prefix)
      removeDir(cwd)
    makeInstalledPrefix(prefix, [])
    let (output, code) = runCopiedImage(prefix, cwd)
    checkpoint(output)
    check code == 0
    check field(output, "RESOLVED") == prefix / InstalledSourceRootSubdir

  test "an explicit REPROBUILD_SOURCE_ROOT still outranks the image's layout":
    let prefix = createTempDir("repro-core-installed-explicit-", "")
    let other = createTempDir("repro-core-explicit-tree-", "")
    let cwd = createTempDir("repro-core-cwd-", "")
    defer:
      removeDir(prefix)
      removeDir(other)
      removeDir(cwd)
    makeInstalledPrefix(prefix, [])
    createDir(other / "libs" / "repro_project_dsl" / "src")
    let (output, code) = runCopiedImage(prefix, cwd,
      [(ReprobuildSourceRootEnvVar, other)])
    checkpoint(output)
    check code == 0
    check field(output, "RESOLVED") == other

  test "a copied image without share/repro resolves nothing and says where " &
      "it looked":
    # This test executable was compiled in a reprobuild checkout that still
    # exists here (`CompiledSourceRoot`). A copy of it elsewhere must not
    # reach back into that checkout: on any other machine the same binary
    # would find nothing, and here it would silently compile against
    # whatever revision the checkout holds now.
    doAssert dirExists(CompiledSourceRoot / "libs" / "repro_project_dsl" /
      "src"), "premise: the build checkout exists on this host"
    let prefix = createTempDir("repro-core-empty-prefix-", "")
    let cwd = createTempDir("repro-core-cwd-", "")
    defer:
      removeDir(prefix)
      removeDir(cwd)
    let (output, code) = runCopiedImage(prefix, cwd)
    checkpoint(output)
    check code == 0
    check field(output, "RESOLVED") == ""
    check field(output, "UNDER_COMPILED") == "false"
    let report = output.split("REPORT-BEGIN")[1].split("REPORT-END")[0]
    check (prefix / InstalledSourceRootSubdir) in report
    check "$" & ReprobuildSourceRootEnvVar & ": unset" in report
    check "$" & ReprobuildRepoRootEnvVar & ": unset" in report
    check CompiledSourceRoot in report
    check "does not run from that checkout" in report

  test "the build checkout arm follows whether this image runs from it":
    # In-process, from a cwd outside any reprobuild tree, with the variables
    # removed: the answer is the build checkout exactly when this executable
    # lives inside it (the usual `build/test-bin/` case), and "" otherwise.
    let cwd = createTempDir("repro-core-cwd-", "")
    let oldCwd = getCurrentDir()
    var saved: seq[(string, string)]
    for name in [ReprobuildLibsDirEnvVar, ReprobuildRepoRootEnvVar,
                 ReprobuildSourceRootEnvVar, PublicCliPathEnvVar]:
      if existsEnv(name):
        saved.add((name, getEnv(name)))
        delEnv(name)
    setCurrentDir(cwd)
    defer:
      setCurrentDir(oldCwd)
      for (name, value) in saved:
        putEnv(name, value)
      removeDir(cwd)
    let expected =
      if runningImageIsUnder(CompiledSourceRoot): CompiledSourceRoot
      else: ""
    check resolveReprobuildSourceRoot() == expected

suite "repro_core/source_root: a staged copy resolves as its source image":
  # The dev-mode user daemon runs a COPY of the engine it was started from,
  # staged under `<daemon state>/dev-bin/<generation>/`, and declares the
  # original with `declareRunningImageSource`. Its compiles must resolve
  # reprobuild's sources exactly as the original image would: from the
  # checkout a `build/bin` engine runs from, or from the installed layout
  # beside an installed one. Measured before the declaration existed: a
  # daemon-hosted `repro build` of a project outside the checkout, started
  # from the checkout's `build/bin/reprobuild.exe`, failed its interface
  # extraction with `blake3.h: No such file or directory`, because the copy
  # no longer counted as running from that checkout.

  test "a copy standing in for an image inside the build checkout " &
      "resolves the checkout":
    doAssert dirExists(CompiledSourceRoot / "libs" / "repro_project_dsl" /
      "src"), "premise: the build checkout exists on this host"
    let prefix = createTempDir("repro-core-staged-copy-", "")
    let cwd = createTempDir("repro-core-cwd-", "")
    defer:
      removeDir(prefix)
      removeDir(cwd)
    # Control: the same copy with nothing declared does not reach the
    # checkout (the case above), so the answer below is the declaration's.
    let bare = runCopiedImage(prefix, cwd)
    check field(bare.output, "RESOLVED") == ""
    let (output, code) = runCopiedImage(prefix, cwd,
      declaredSource = CompiledSourceRoot / "build" / "bin" /
        extractFilename(getAppFilename()))
    checkpoint(output)
    check code == 0
    check field(output, "UNDER_COMPILED") == "true"
    check field(output, "RESOLVED") == CompiledSourceRoot

  test "a copy standing in for an installed image resolves that image's " &
      "share/repro/source":
    let installed = createTempDir("repro-core-staged-installed-", "")
    let stagedPrefix = createTempDir("repro-core-staged-dev-bin-", "")
    let cwd = createTempDir("repro-core-cwd-", "")
    defer:
      removeDir(installed)
      removeDir(stagedPrefix)
      removeDir(cwd)
    makeInstalledPrefix(installed, [])
    let (output, code) = runCopiedImage(stagedPrefix, cwd,
      declaredSource = installed / "bin" / addFileExt("reprobuild", ExeExt))
    checkpoint(output)
    check code == 0
    check field(output, "RESOLVED") == installed / InstalledSourceRootSubdir
