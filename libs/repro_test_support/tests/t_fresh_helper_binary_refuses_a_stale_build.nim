## A test's helper binary is used only when it was built from the tree
## under test (reprobuild-pm issue 2026-11-07-addon-allow-listed-source-
## field-turns-the-sinks-redaction-case-red-masked-by-a-stale-sink).
##
## A small tree -- an app and a library module it imports -- is compiled by
## the real Nim into ``build/bin`` with its own nimcache, as
## ``scripts/build_apps.sh`` does, and ``freshRepoBinary`` is asked for it:
##
## 1. Built from the tree as it is: the binary is returned, and its
##    dependencies, read from Nim's build record, include both the app's
##    module and the library module (Nim's generated-file names decoded).
## 2. A library module edited after the build: refused, naming the module.
## 3. The app's own module edited after an incremental rebuild that
##    compiled nothing (Nim's record then lists no compiled file, only the
##    linked objects): refused.
## 4. Rebuilt: accepted again.
## 5. No binary, or no build record: refused.
##
## Falsifying build: ``-d:reproAddonMutation=stale-helper-accepted``
## (cases 2 and 3 go red).
##
## Mocks: none -- the real compiler, the real build record.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support/fresh_binary

let tree = createTempDir("fresh-binary-", "")
let lib = tree / "libs" / "foolib" / "src" / "foolib" / "bar.nim"
let app = tree / "apps" / "foo" / "foo.nim"
createDir(parentDir(lib))
createDir(parentDir(app))
writeFile(lib, "proc greeting*(): string = \"hello\"\n")
writeFile(app, "import foolib/bar\necho greeting()\n")

proc build() =
  ## Compile the tree, after dating its sources a minute back (an earlier
  ## case may have dated one into the future).
  for src in [lib, app]:
    setLastModificationTime(src, getTime() - initDuration(seconds = 60))
  let cmd = quoteShellCommand(["nim", "c", "--hints:off", "--warnings:off",
    "--path:" & tree / "libs" / "foolib" / "src",
    "--nimcache:" & tree / "build" / "nimcache" / "foo",
    "--out:" & tree / "build" / "bin" / "foo", app])
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, output

proc touchAfterBinary(path: string) =
  ## Mark ``path`` edited ten seconds after the binary was built, without
  ## depending on the file system's timestamp resolution.
  let built = getLastModificationTime(tree / "build" / "bin" / addFileExt("foo", ExeExt))
  setLastModificationTime(path, built + initDuration(seconds = 10))

proc refusal(): string =
  try:
    discard freshRepoBinary(tree, "foo")
    ""
  except StaleHelperBinary as e:
    e.msg

suite "a helper binary is used only when built from the tree under test":
  test "1: built from the tree as it is, it is returned":
    build()
    check freshRepoBinary(tree, "foo") ==
      tree / "build" / "bin" / addFileExt("foo", ExeExt)
    let deps = helperDependencies(tree, "foo")
    checkpoint deps.join("\n")
    check lib in deps
    check app in deps

  test "2: a library module edited after the build is refused":
    touchAfterBinary(lib)
    let why = refusal()
    checkpoint why
    check "older than " & lib in why
    check "just build" in why

  test "3: the app's module edited after the build is refused":
    build()
    check refusal() == ""
    touchAfterBinary(app)
    let why = refusal()
    checkpoint why
    check ("older than " & app) in why

  test "4: rebuilt, it is accepted again":
    build()
    check refusal() == ""

  test "5: no binary, or no build record, is refused":
    removeFile(tree / "build" / "nimcache" / "foo" / "foo.json")
    check "has no build record" in refusal()
    removeFile(tree / "build" / "bin" / addFileExt("foo", ExeExt))
    check "does not exist" in refusal()

removeDir(tree)
