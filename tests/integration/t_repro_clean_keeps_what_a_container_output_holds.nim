## ``repro clean`` removes a CONTAINER directory output only by removing its
## members and then the directory itself if nothing else is left in it. It
## never deletes the container's tree.
##
## A container directory output (Incremental-Invalidation.md §"Non-regular
## outputs", "Container directory outputs") is a directory that a built-in
## declares only to say that it exists:
##
##   * ``fs.ensureDir`` creates the directory and writes nothing into it;
##     other actions write into it (CodeTracer's C compiles write
##     ``build/c/*.o`` into ``fs.ensureDir("build/c")``);
##   * ``fs.preserveTree`` declares its output root, and declares each entry
##     it copies as an output of its own.
##
## The container's other entries are other actions' declared outputs or files
## that no action declares, so they are not the built-in's product. clean.md
## §"Ownership Records" says that nothing no claim names is touched, and that
## every file the user placed under the project survives a clean. A clean that
## removed a container with ``removeDir`` deleted those files (reprobuild-pm
## issues/2026-11-12-repro-clean-recursively-deletes-container-directories-including-files-that-no-action.md).
##
## The fixture has one ``fs.ensureDir("build/c")``, one ``fs.copyFile`` that
## writes into it, and one ``fs.preserveTree`` of a source tree with a nested
## directory into ``build/pub``. The cases check:
##
##   * user files inside both containers, one of them in a nested directory
##     of the ``preserveTree`` root, survive the clean. The declared members
##     are removed, and the containers stay because they are not empty;
##   * without user files, the clean removes every member, the nested
##     directory that the members' removal left empty, and both containers;
##   * ``--dry-run`` removes nothing.
##
## An opaque directory output, the declared output of a process action, is
## still removed with its whole tree; t_output_cleanup_executor covers that
## rule at the executor level.
##
## No mocks: the test spawns the built ``repro`` binary against a real
## fixture project, and the binary, the provider-graph snapshots and the
## filesystem are the real components under test. Built-in ``fs`` actions
## need no toolchain beyond the provider compile the CLI does for any recipe.

import repro_test_support/reasoned_skip
import std/[os, osproc, strutils, unittest]

const reproBinary =
  when defined(windows): "build/bin/repro.exe" else: "build/bin/repro"

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc q(value: string): string = quoteShell(value)

proc writeFixture(projRoot: string) =
  createDir(projRoot / "src" / "pub" / "nested")
  writeFile(projRoot / "src" / "main.txt", "main\n")
  writeFile(projRoot / "src" / "pub" / "top.txt", "top\n")
  writeFile(projRoot / "src" / "pub" / "nested" / "deep.txt", "deep\n")
  writeFile(projRoot / "repro.nim", """
import repro_dsl_stdlib

package containerclean:
  defaultToolProvisioning "path"
  build:
    let dir = fs.ensureDir("build/c", actionId = "make_c_dir")
    let obj = fs.copyFile("src/main.txt", "build/c/main.o",
      actionId = "compile_main", after = [dir])
    let pub = fs.preserveTree("src/pub", "build/pub", actionId = "stage_pub")
    target("all", @[dir, obj, pub])
""")

type Fixture = object
  repoRoot, reproAbs, scratch, projRoot: string

proc newFixture(repoRoot, tag: string): Fixture =
  result.repoRoot = repoRoot
  result.reproAbs = repoRoot / reproBinary
  result.scratch = getTempDir() / ("t_repro_clean_container-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.scratch)
  createDir(result.scratch)
  result.projRoot = result.scratch / "proj"
  writeFixture(result.projRoot)

proc build(f: Fixture): tuple[code: int; output: string] =
  # ``--no-runquota`` and ``--daemon=off`` keep the run in this process tree.
  let cmd = q(f.reproAbs) & " build " & q(f.projRoot / "repro.nim") &
    " --tool-provisioning=path --daemon=off --no-runquota" &
    " --log=quiet --progress=quiet --measure=none" &
    " --action-cache-root=" & q(f.scratch / "action-cache")
  let res = execCmdEx(cmd, workingDir = f.repoRoot)
  (code: res.exitCode, output: res.output)

proc clean(f: Fixture; extra = ""): tuple[code: int; output: string] =
  let res = execCmdEx(q(f.reproAbs) & " clean" & extra,
    workingDir = f.projRoot)
  (code: res.exitCode, output: res.output)

proc builtOutputs(f: Fixture): seq[string] =
  ## The declared member outputs the build writes into the two containers.
  @[f.projRoot / "build" / "c" / "main.o",
    f.projRoot / "build" / "pub" / "top.txt",
    f.projRoot / "build" / "pub" / "nested" / "deep.txt"]

suite "repro clean and container directory outputs":

  test "t_repro_clean_keeps_user_files_inside_a_container":
    let repoRoot = findRepoRoot()
    if not fileExists(repoRoot / reproBinary):
      skip("build/bin/repro not built; this case spawns the repro binary " &
        "(run `just build` first)")
    else:
      let f = newFixture(repoRoot, "keep")
      defer: removeDir(f.scratch)
      let (code1, out1) = f.build()
      checkpoint(out1)
      check code1 == 0
      for path in f.builtOutputs():
        check fileExists(path)

      # Files no action declares, placed in each container: at the top of
      # the ensureDir directory, at the top of the preserveTree root, and in
      # the nested directory the preserveTree created.
      let userInC = f.projRoot / "build" / "c" / "notes.txt"
      let userInPub = f.projRoot / "build" / "pub" / "local.cfg"
      let userNested = f.projRoot / "build" / "pub" / "nested" / "mine.txt"
      writeFile(userInC, "c notes\n")
      writeFile(userInPub, "pub cfg\n")
      writeFile(userNested, "nested mine\n")

      let (codeDry, outDry) = f.clean(" --dry-run")
      checkpoint(outDry)
      check codeDry == 0
      for path in f.builtOutputs():
        check ("would remove " & path) in outDry
        check fileExists(path)
      check fileExists(userInC)
      check fileExists(userInPub)
      check fileExists(userNested)

      let (code2, out2) = f.clean()
      checkpoint(out2)
      check code2 == 0
      # The issue's failure: the container was removed with its tree, and
      # with it every file the user had placed there.
      check fileExists(userInC)
      check fileExists(userInPub)
      check fileExists(userNested)
      if fileExists(userInC): check readFile(userInC) == "c notes\n"
      if fileExists(userNested): check readFile(userNested) == "nested mine\n"
      # The containers' declared members are gone; the containers are not,
      # because they still hold files that are not theirs.
      for path in f.builtOutputs():
        check not fileExists(path)
      check dirExists(f.projRoot / "build" / "c")
      check dirExists(f.projRoot / "build" / "pub" / "nested")
      check ("removed " & f.projRoot / "build" / "c") notin out2.splitLines()
      check ("removed " & f.projRoot / "build" / "pub") notin out2.splitLines()
      check "repro clean: kept build/c" in out2
      check "repro clean: kept build/pub" in out2
      # The sources the preserveTree mirrored are untouched.
      check readFile(f.projRoot / "src" / "pub" / "nested" / "deep.txt") ==
        "deep\n"

  test "t_repro_clean_removes_an_emptied_container":
    let repoRoot = findRepoRoot()
    if not fileExists(repoRoot / reproBinary):
      skip("build/bin/repro not built; this case spawns the repro binary " &
        "(run `just build` first)")
    else:
      let f = newFixture(repoRoot, "empty")
      defer: removeDir(f.scratch)
      let (code1, out1) = f.build()
      checkpoint(out1)
      check code1 == 0
      for path in f.builtOutputs():
        check fileExists(path)
      # A file of the user's beside the containers, which no claim names.
      let userBeside = f.projRoot / "build" / "README.txt"
      writeFile(userBeside, "beside\n")

      let (code2, out2) = f.clean()
      checkpoint(out2)
      check code2 == 0
      for path in f.builtOutputs():
        check not fileExists(path)
      # The nested directory held only declared members; once they are gone
      # nothing is left of it, and the two containers are empty and removed.
      check not dirExists(f.projRoot / "build" / "pub" / "nested")
      check not dirExists(f.projRoot / "build" / "pub")
      check not dirExists(f.projRoot / "build" / "c")
      check ("removed " & f.projRoot / "build" / "c") in out2.splitLines()
      check ("removed " & f.projRoot / "build" / "pub") in out2.splitLines()
      check readFile(userBeside) == "beside\n"

      let (code3, out3) = f.clean()
      checkpoint(out3)
      check code3 == 0
      check "repro clean: removed 0 output(s)" in out3
